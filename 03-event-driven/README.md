# 03-event-driven

SNS fan-out: one topic, two SQS subscriptions (one unfiltered, one with a
FilterPolicy), two Lambda consumers, one shared DynamoDB sink. Shipped via
a single CloudFormation template.

Two integration tests:
1. `test_fanout_filter_policy`: small order reaches only emails; big order
   reaches both queues.
2. `test_payload_is_preserved`: the original JSON survives the
   SNS → SQS → Lambda envelope unwrap.

## Layout

```
03-event-driven/
├── cfn/stack.yaml              # 13 resources, inline Lambda code
├── tests/test_fanout.py        # 2 tests
└── scripts/{deploy,test,teardown}.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```
