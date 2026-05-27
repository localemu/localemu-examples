# 05-batch-etl

A Step Functions Standard workflow that parses a CSV from S3 and fans
out a Map state over the rows. One Lambda parses, another loads into
DynamoDB; per-row Catch routes bad rows to a Pass state so one bad row
does not abort the batch.

Two integration tests:
1. `test_etl_happy_path` (data plane): four valid rows land, two bad
   rows are skipped.
2. `test_run_output_shape` (control plane): Map's aggregated output has
   4 loaded + 2 rejected entries.

## Layout

```
05-batch-etl/
├── sample/orders.csv           # 6 rows: 4 valid, 2 bad
├── src/parse.py + load_row.py  # 2 Lambdas
├── terraform/                  # 9 resources
├── tests/test_etl.py           # 2 tests
└── scripts/{deploy,test,teardown}.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```
