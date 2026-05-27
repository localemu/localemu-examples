# 06-s3-guardrail

CloudTrail → EventBridge → Lambda auto-remediation: any S3 bucket whose
access surface just widened gets PAB(all=true) applied, an incident row
written to DynamoDB (deduped by CloudTrail eventID), and an SNS alert
published.

Seven integration tests:
- 6 direct-invoke of the Lambda (happy path, private no-op, dedup,
  missing bucket, missing bucketName, rule-pattern shape)
- 1 end-to-end: create a public bucket, watch the full pipeline
  remediate it without touching the Lambda directly.

## Layout

```
06-s3-guardrail/
├── src/handler.py              # ~150 lines
├── terraform/                  # 11 resources
├── tests/test_guardrail.py     # 7 tests
└── scripts/{deploy,test,teardown}.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```
