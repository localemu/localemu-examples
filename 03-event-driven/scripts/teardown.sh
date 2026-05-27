#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
STACK="${STACK_NAME:-le-events}"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT=(--endpoint-url http://localhost:4566)
  export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY AWS_DEFAULT_REGION=us-east-1
else
  ENDPOINT=()
fi

echo "→ deleting stack '$STACK' on $TARGET"
aws cloudformation delete-stack --stack-name "$STACK" "${ENDPOINT[@]}"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" "${ENDPOINT[@]}" || true

echo
echo "→ verifying teardown for prefix 'le-events' on $TARGET"

leaks=0
if aws dynamodb describe-table --table-name "le-events-events" "${ENDPOINT[@]}" >/dev/null 2>&1; then
  echo "  LEAK: dynamodb table le-events-events"
  leaks=$((leaks+1))
fi
for q in le-events-emails le-events-alerts; do
  if aws sqs get-queue-url --queue-name "$q" "${ENDPOINT[@]}" >/dev/null 2>&1; then
    echo "  LEAK: sqs queue $q"
    leaks=$((leaks+1))
  fi
done
for fn in le-events-emails-consumer le-events-alerts-consumer; do
  if aws lambda get-function --function-name "$fn" "${ENDPOINT[@]}" >/dev/null 2>&1; then
    echo "  LEAK: lambda $fn"
    leaks=$((leaks+1))
  fi
done

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
