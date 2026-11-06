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

## Requires

- Docker, [Terraform](https://developer.hashicorp.com/terraform/install) and Python 3
- Python packages for the tests: `pip install -r requirements.txt` (`boto3`, `pytest`)

## Running locally

```sh
pip install -r requirements.txt

docker run -d --name localemu --user root -p 4566:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  localemu/localemu:latest      # the Lambda runs in a sibling container, so the Docker socket is needed

./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```

## Timing of the end-to-end test

LocalEmu forwards CloudTrail management events to EventBridge after a 15 second
delay, because real CloudTrail does not deliver instantly (we measured 5.5 s to
23.7 s, median 14.5 s, on a real AWS account). The end-to-end test therefore
takes about 15 to 20 seconds and waits up to 60 seconds for the bucket to be
locked. Against real AWS (`TARGET=aws`) it waits up to 1200 seconds.
