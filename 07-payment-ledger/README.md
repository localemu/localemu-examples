# 07-payment-ledger

The Stripe-style payment API: `Idempotency-Key` header + DynamoDB
`TransactWriteItems` doing payer debit, payee credit, two ledger rows,
and the idempotency record in one atomic shot.

Nine integration tests, including a 5-way concurrent-debit race that
asserts exactly one winner and no overdraws.

## Layout

```
07-payment-ledger/
├── src/handler.py              # POST /payments + transactional handler
├── terraform/                  # 16 resources
├── tests/test_payments.py      # 9 tests
└── scripts/{deploy,test,teardown}.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```
