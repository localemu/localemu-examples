# 10-microservices

A mini e-commerce event-driven system: three Python services that
communicate through SNS and SQS.

- `order_service.py` publishes order events to an SNS topic.
- `payment_service.py` polls a payment SQS queue, records payments to
  DynamoDB.
- `notification_service.py` polls a separate notification SQS queue,
  records sent notifications to DynamoDB.

One publish, two DynamoDB tables updated via independent services
subscribed to the same topic: the fan-out pattern, built and tested
locally.

## Layout

```
10-microservices/
├── src/
│   ├── order_service.py
│   ├── payment_service.py
│   └── notification_service.py
├── tests/test_ecommerce.py
└── scripts/{setup,test,teardown}.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/setup.sh                # create topic + queues + subscriptions + tables
./scripts/test.sh                 # one end-to-end integration test
./scripts/teardown.sh             # remove everything, verify clean
```

## Why not use 03-event-driven instead?

That tutorial ships the same fan-out pattern via CloudFormation + Lambda
consumers. This one uses plain Python services that poll, which is
closer to how many teams structure long-running microservices outside
AWS Lambda. The messaging topology is the same; only the consumer
runtime differs.
