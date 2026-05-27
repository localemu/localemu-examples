#!/usr/bin/env bash
# Create the SNS topic, SQS queues + subscriptions, and DynamoDB tables for
# the mini e-commerce system. Idempotent: safe to run multiple times.
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

echo "→ creating SNS topic order-events..."
aws $ENDPOINT sns create-topic --name order-events >/dev/null

echo "→ creating SQS queues payment-queue + notification-queue..."
aws $ENDPOINT sqs create-queue --queue-name payment-queue >/dev/null
aws $ENDPOINT sqs create-queue --queue-name notification-queue >/dev/null

echo "→ subscribing both queues to the topic..."
aws $ENDPOINT sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:000000000000:order-events \
  --protocol sqs \
  --notification-endpoint arn:aws:sqs:us-east-1:000000000000:payment-queue >/dev/null

aws $ENDPOINT sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:000000000000:order-events \
  --protocol sqs \
  --notification-endpoint arn:aws:sqs:us-east-1:000000000000:notification-queue >/dev/null

echo "→ creating DynamoDB tables payments + notifications..."
aws $ENDPOINT dynamodb create-table \
  --table-name payments \
  --key-schema AttributeName=order_id,KeyType=HASH \
  --attribute-definitions AttributeName=order_id,AttributeType=S \
  --billing-mode PAY_PER_REQUEST 2>/dev/null || echo "  payments already exists"

aws $ENDPOINT dynamodb create-table \
  --table-name notifications \
  --key-schema AttributeName=order_id,KeyType=HASH \
  --attribute-definitions AttributeName=order_id,AttributeType=S \
  --billing-mode PAY_PER_REQUEST 2>/dev/null || echo "  notifications already exists"

aws $ENDPOINT dynamodb wait table-exists --table-name payments
aws $ENDPOINT dynamodb wait table-exists --table-name notifications

echo "→ all resources ready."
