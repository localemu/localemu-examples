# 22-guardduty-autoremediation

A GuardDuty finding to EventBridge to Lambda **containment** loop — a
minimal Cloud Detection & Response (CDR) pipeline. GuardDuty flags a
compromised identity (e.g. an EC2 instance role whose credentials were
phished via SSRF -> IMDS), and the responder Lambda:

- quarantines an assumed-role session with the surgical AWS IR pattern —
  a Deny conditioned on `aws:TokenIssueTime`, cutting off only sessions
  already in the attacker's hands,
- quarantines an IAM user with an unconditional Deny-all (no session to
  gate on issue time) and deactivates the leaked access key,
- logs an incident (deduped by GuardDuty finding id),
- publishes an SNS alert.

Seven integration tests:
- 6 direct-invoke of the Lambda (assumed-role quarantine, IAM-user
  quarantine + key deactivation, dedup, non-actionable finding type,
  missing principal, missing finding id)
- 1 end-to-end: publish a finding straight to EventBridge and watch the
  full pipeline react, without touching the Lambda directly.

## Two LocalEmu gaps this example surfaced — both now fixed upstream

Running this example for real against an earlier LocalEmu build surfaced
two genuine gaps. Both are now fixed in LocalEmu itself (not just worked
around here) — this section is kept as a record of what was actually
broken and verified, not a live caveat list.

**1. `CreateSampleFindings` / `ListFindings` / `GetFindings` were not
implemented at all** (`No moto route for service guardduty on path
/detector/<id>/findings/create found`). Fixed with a native finding
store (`localemu/services/guardduty/`) — `CreateSampleFindings` now also
auto-forwards to EventBridge, matching real AWS. `scripts/attack.sh`
calls the real API first to prove it, **and** still injects a
schema-accurate finding by hand for the actual containment demo — not
because LocalEmu can't generate findings anymore, but because
`CreateSampleFindings` (on LocalEmu *and* real AWS) always names a
generic placeholder identity, never a real resource in your account. You
can't demonstrate containing an identity that doesn't exist, on either
platform — that part of this demo was never a LocalEmu gap.

**2. `aws:TokenIssueTime` was not populated as an IAM condition key**
under `IAM_ENFORCEMENT=1`, so the Deny above would have silently never
fired. Fixed by threading an `issued_at` timestamp through STS session
creation (`localemu/services/sts/`) into the IAM condition-evaluation
context (`localemu/services/iam_enforcement/enforcer.py`). `responder.py`
now uses the real, surgical technique — verified live: the stolen
session is denied, a fresh session assumed *after* containment is not.

Both fixes shipped alongside this workshop; see the LocalEmu repo history
for the actual patches if you want to read them.

## Layout

```
22-guardduty-autoremediation/
├── src/responder.py             # ~190 lines
├── terraform/                   # 11 resources
├── tests/test_guardduty_response.py  # 7 tests
└── scripts/{deploy,test,teardown,attack}.sh
```

## Requires

LocalEmu started with `IAM_ENFORCEMENT=1` — the quarantine policy's whole
point is to be enforced:

```sh
IAM_ENFORCEMENT=1 localemu start
```

## Running the test suite

```sh
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```

## Running the live demo (red team, then blue team)

```sh
./scripts/deploy.sh local
./scripts/attack.sh      # assumes the victim role, shows the stolen
                          # session working, injects the finding, then
                          # shows the same stolen session denied
./scripts/teardown.sh local
```
