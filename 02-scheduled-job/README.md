# 02-scheduled-job

An hourly EventBridge Scheduler triggers a Lambda that lists Managed=true
secrets from Secrets Manager, classifies each one as `ok` or
`needs_rotation`, and writes an audit row to DynamoDB per (secret, run).

Three tests, no clock-watching: `GetSchedule` for plumbing, direct
`lambda:Invoke` for behaviour.

## Layout

```
02-scheduled-job/
├── src/rotation_check.py
├── terraform/                   # 13 resources
├── tests/test_scheduled_job.py  # 3 tests
└── scripts/{deploy,test,teardown}.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```
