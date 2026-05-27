#!/usr/bin/env bash
set -euo pipefail
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

echo "→ deleting queues, topic, and tables..."
aws $ENDPOINT sqs delete-queue --queue-url http://localhost:4566/000000000000/payment-queue 2>/dev/null || true
aws $ENDPOINT sqs delete-queue --queue-url http://localhost:4566/000000000000/notification-queue 2>/dev/null || true
aws $ENDPOINT sns delete-topic --topic-arn arn:aws:sns:us-east-1:000000000000:order-events 2>/dev/null || true
aws $ENDPOINT dynamodb delete-table --table-name payments 2>/dev/null || true
aws $ENDPOINT dynamodb delete-table --table-name notifications 2>/dev/null || true

echo "→ verifying teardown"
leaks=0
for q in payment-queue notification-queue; do
  if aws $ENDPOINT sqs get-queue-url --queue-name "$q" 2>/dev/null; then
    echo "  LEAK: sqs queue $q"
    leaks=$((leaks+1))
  fi
done
for t in payments notifications; do
  if aws $ENDPOINT dynamodb describe-table --table-name "$t" 2>/dev/null; then
    echo "  LEAK: dynamodb table $t"
    leaks=$((leaks+1))
  fi
done
if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
