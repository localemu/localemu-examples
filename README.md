# localemu-examples

End-to-end working tutorials for [LocalEmu](https://localemu.cloud), the
open-source AWS emulator. Each folder is a self-contained project with
real Terraform (or CloudFormation), real Lambda code, real integration
tests, and a `scripts/` directory you can run top to bottom. Every
tutorial has been deployed, tested green, and torn down cleanly on
LocalEmu.

The tutorials come in two shapes:

- **Application patterns** drive an end-to-end build with three scripts:
  `deploy.sh` (Terraform or CloudFormation), `test.sh` (pytest), and
  `teardown.sh`. A couple of edge-case patterns substitute `setup.sh`
  for `deploy.sh` or drop the provisioning step entirely; the per-folder
  README calls out the difference.
- **Service demos** are single-script walkthroughs: a `demo.sh`
  exercises the full scenario in one pass, and `teardown.sh` cleans
  up.

## Tutorials

### Application patterns (build, test, teardown)

| Folder | What it builds |
|---|---|
| [`01-rest-api/`](./01-rest-api) | Five-route CRUD notes on API Gateway v2 + Lambda + DynamoDB |
| [`02-scheduled-job/`](./02-scheduled-job) | Hourly EventBridge Scheduler Lambda checking Secrets Manager rotation age |
| [`03-event-driven/`](./03-event-driven) | SNS fan-out with FilterPolicy to two SQS queues + two Lambdas (CloudFormation) |
| [`04-image-pipeline/`](./04-image-pipeline) | S3 upload to Lambda (Pillow thumbnail) to SNS + CloudWatch |
| [`05-batch-etl/`](./05-batch-etl) | Step Functions Map over CSV rows with per-row Catch |
| [`06-s3-guardrail/`](./06-s3-guardrail) | CloudTrail to EventBridge to Lambda auto-remediation of public S3 buckets |
| [`07-payment-ledger/`](./07-payment-ledger) | DynamoDB TransactWriteItems + Idempotency-Key + 5-way concurrent-debit race |
| [`08-llm-gateway/`](./08-llm-gateway) | Guardrailed, cached, evaluated LLM gateway (API GW + Lambda + DDB + EB + SQS + CW) |
| [`09-ci-cd/`](./09-ci-cd) | Lambda handler unit tests against a LocalEmu service, runnable from any CI |
| [`10-microservices/`](./10-microservices) | SNS + 2 SQS + 2 DynamoDB-table mini e-commerce wired up via plain `aws` CLI |

### Service demos (one-shot walkthroughs)

| Folder | What it demonstrates | Required env |
|---|---|---|
| [`11-cognito-demo/`](./11-cognito-demo) | User pool + client + user lifecycle | none |
| [`12-kinesis-demo/`](./12-kinesis-demo) | Stream create, PutRecord, GetRecords round-trip | none |
| [`13-opensearch-demo/`](./13-opensearch-demo) | Domain create (real OpenSearch container), index, search | none |
| [`14-rds-demo/`](./14-rds-demo) | Postgres + MySQL DB instances, psql + mysql clients, Python round-trip | `RDS_DOCKER_BACKEND=1` |
| [`15-ec2-demo/`](./15-ec2-demo) | RunInstances spins a real Docker container; reach it via `localemu ssh`, real in-VPC SSH, EC2 Instance Connect, or SSM | none |
| [`16-ecs-demo/`](./16-ecs-demo) | Cluster + task definition + RunTask, real containers behind the API | none |
| [`17-eks-demo/`](./17-eks-demo) | EKS cluster via k3d, `kubectl apply`, real pod deploy | none |
| [`18-transit-gateway-demo/`](./18-transit-gateway-demo) | Three VPCs, TGW + peering, connectivity matrix verified end-to-end | none |
| [`19-iam-least-privilege/`](./19-iam-least-privilege) | Provably-minimum IAM policy via Sid-removal mutation testing | `IAM_ENFORCEMENT=1` |
| [`20-stepfunctions-saga/`](./20-stepfunctions-saga) | Saga compensation across three failure injection points | none |
| [`21-chaos-resilience/`](./21-chaos-resilience) | Load test with zero-data-loss assertion under retry pressure | none |

All tutorials are tested end-to-end against both the pip install and
the Docker image of LocalEmu.

## Prerequisites

- Python 3.10+ with `pytest`, `boto3`, `requests`, `Pillow` (for the image-pipeline pattern)
- Terraform 1.5+
- The AWS CLI
- LocalEmu running locally on port 4566 (`localemu start`)

## Usage

Application patterns (`deploy.sh` + `test.sh` + `teardown.sh`):

```sh
cd <tutorial-folder>
./scripts/deploy.sh    local   # or: aws
./scripts/test.sh      local
./scripts/teardown.sh  local
```

A few application patterns substitute `setup.sh` for `deploy.sh` or
skip the provisioning step entirely; the per-folder README explains
the deviation. The `local` / `aws` argument flips a single Terraform
variable (or the `--endpoint-url` on CloudFormation patterns).
Nothing else changes between targets.

Service demos:

```sh
cd <tutorial-folder>
./scripts/demo.sh
./scripts/teardown.sh
```

A handful require LocalEmu to be started with a specific env var (see
the Service demos table above). The walkthrough's `README.md` repeats
the prerequisite at the top.

## License

Apache 2.0.
