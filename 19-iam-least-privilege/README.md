# 19-iam-least-privilege

Mechanized **least-privilege test** for an AWS IAM policy: take a
Lambda that touches six services, compile a "golden" policy that
authorizes exactly one action per service, then **mutate** it, one
Sid removed at a time, and assert the Lambda fails with AccessDenied
on exactly the expected action.

If every mutation fails on exactly the right action:

- every Sid is **justified** (removing it breaks something), and
- no Sid is **over-privileged** (removing it only breaks one action,
  meaning nothing else was covertly authorizing that action too).

This is the mechanical version of the thing every AWS team hand-waves
about: "our IAM is least-privilege, trust us." With this pattern, you
don't trust. You prove.

## What the Lambda does

A single Python handler performs six API calls in strict order, each
targeting one of the provisioned resources. If any call returns
AccessDenied, the handler stops and returns a JSON body naming the
failed action; otherwise it returns `{"status": "ok"}` with a full
trace. That structured response is what the mutation loop asserts on.

| Step | Action                             | Resource type      |
|------|------------------------------------|--------------------|
| 1    | `s3:GetObject`                     | S3 bucket object   |
| 2    | `kms:Decrypt`                      | KMS key            |
| 3    | `ssm:GetParameter`                 | SSM Parameter      |
| 4    | `secretsmanager:GetSecretValue`    | Secrets Manager    |
| 5    | `dynamodb:PutItem`                 | DynamoDB table     |
| 6    | `sns:Publish`                      | SNS topic          |

## What the run proves

```
== 5. Invoke the Lambda under the golden policy: expect status=ok ==
  ✓ Baseline green: golden policy lets all 6 steps through

== 6. Mutation loop: remove each Sid, expect its action to be denied ==
  ✓ denied_action=s3:GetObject                    (as expected)
  ✓ denied_action=kms:Decrypt                     (as expected)
  ✓ denied_action=ssm:GetParameter                (as expected)
  ✓ denied_action=secretsmanager:GetSecretValue   (as expected)
  ✓ denied_action=dynamodb:PutItem                (as expected)
  ✓ denied_action=sns:Publish                     (as expected)

  🎉  All 6/6 mutations denied exactly the expected action.
       Golden policy is provably minimum-viable.
```

Total runtime: ~15 s.

## Why this is not possible on real AWS (practically)

- `iam:PutRolePolicy` on the live account is a slow, audited,
  production-affecting operation. Running 7 iterations of it in a
  test loop is not something you do against prod IAM.
- Even on a dev account, each iteration pays IAM's propagation
  latency. Real AWS takes seconds to tens of seconds for the new
  policy to fully apply everywhere. The loop becomes minutes.
- LocalEmu's IAM policy evaluator is **in-process**, so
  put-role-policy is effectively instant and the next Lambda invoke
  evaluates under the new policy.

## Requires

- LocalEmu started with `IAM_ENFORCEMENT=1`:

  ```sh
  IAM_ENFORCEMENT=1 EC2_VM_MANAGER=docker localemu start
  ```

  (The EC2 flag isn't strictly needed for this tutorial but most real
  setups have it on anyway.)

- `aws` CLI (v1 or v2), `python3`, `zip`.

## Running

```sh
./scripts/demo.sh       # setup + baseline + 6 mutations, ~15 s
./scripts/teardown.sh   # clean up
```

Each phase is also runnable on its own:

```sh
./infra/01_setup.sh      # provision 6 resources + Lambda + role
./infra/02_baseline.sh   # attach golden policy, invoke, expect status=ok
./infra/03_mutate.sh     # 6 mutations, each must deny exactly one action
./scripts/teardown.sh
```

Ids from step 01 are written to `.state/ids.env`; later steps source
that file.

## Layout

```
19-iam-least-privilege/
├── README.md
├── scripts/
│   ├── demo.sh           <- end-to-end orchestrator
│   └── teardown.sh       <- best-effort cleanup
├── lib/
│   └── common.sh         <- awsx wrapper, logging, invoke_lambda helper
├── src/
│   └── handler.py        <- the Lambda: 6 API calls, structured response
└── infra/
    ├── 01_setup.sh       <- provision + Lambda + role (logs-only baseline)
    ├── 02_baseline.sh    <- attach golden policy, invoke, assert ok
    └── 03_mutate.sh      <- the mutation loop
```

## Why a scoped `KeyId` on `kms:Decrypt`

The handler passes `KeyId` explicitly to `kms:Decrypt`. This is a
deliberate AWS-best-practice in this context:

- Without `KeyId`, AWS infers the target key from the ciphertext
  header. That still works on real AWS for authorization
  (AWS parses the header before evaluating IAM), but LocalEmu's IAM
  arn-builder can only see the API parameters. With no `KeyId`
  param, it can't narrow the resource ARN past
  `arn:aws:kms:*:*:key/*`, which forces you to widen the policy.
- Passing `KeyId` explicitly lets IAM scope the `kms:Decrypt` grant
  to a single key, which is what you actually want.

Pattern to remember: if you want a narrow `kms:Decrypt` policy,
always pass `KeyId` explicitly at the SDK call site.

## What this exercises in LocalEmu

- `IAM_ENFORCEMENT=1`: full AWS policy evaluation for every API call.
- `iam:PutRolePolicy` / `iam:DeleteRolePolicy`: the fast in-process
  policy swap that makes the mutation loop feasible.
- `sts:AssumeRole` by `lambda.amazonaws.com` with per-role session
  credentials, the same mechanism AWS Lambda uses.
- Lambda invocation under STS-derived credentials, so each business
  API call is evaluated against the role's attached policies.
- Resource-scoped ARN building for all six services.
