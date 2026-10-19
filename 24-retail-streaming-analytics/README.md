# 24-retail-streaming-analytics

A real streaming ingestion-to-analytics pipeline: order/clickstream
events in, SQL aggregates out — the first example in this repo to
exercise Firehose, Glue, and Athena together as one real pipeline, not
three separate service demos.

```
scripts/produce.py  ->  Firehose (DirectPut)  ->  S3  ->  Glue table  ->  Athena SQL
```

Six integration tests against a real, fixed, known batch of events: total
count, GROUP BY aggregation, a customer filter, a cancellation-rate
calculation, a direct S3 check of the exact newline-delimiting gotcha
this lab is built around, and an empty-result (not an error) case.

## Two things worth knowing, found by actually building this

**1. Firehose records have no delimiter of their own — you add the
newline, or Athena sees one malformed blob.** Real AWS behavior, not a
LocalEmu quirk: Firehose concatenates each `PutRecord` payload
back-to-back in the delivered file with nothing in between. `produce.py`
appends `\n` after every JSON record for exactly this reason — skip it
and a two-record file reads as `{...}{...}`, which no JSON parser
accepts. `test_delivered_files_are_newline_delimited_json` checks this
directly, not just indirectly through a passing query.

**2. Firehose's `KinesisStreamAsSource` mode doesn't deliver anything
today.** The architecture you'd expect for "real" streaming analytics is
producer -> Kinesis -> Firehose -> S3, so that's what we tried first.
`CreateDeliveryStream` with a `KinesisStreamSourceConfiguration` succeeds,
and the consumer genuinely polls the stream (confirmed via continuous
`kinesis.GetRecords => 200` in the server log) — but no record ever
reaches S3, with the exact same destination config that delivers in
seconds under plain `DirectPut`. Confirmed by direct comparison: swapping
only the source (Kinesis vs. DirectPut) on an otherwise identical
destination is the difference between nothing arriving and immediate
delivery. This example uses `DirectPut` instead — a legitimate, common
real-AWS pattern on its own (e.g. a Lambda-based ingestion layer writing
straight to Firehose), not a downgrade — but the Kinesis-as-source gap is
real and worth filing upstream if you want the "producer writes to
Kinesis, Firehose fans out to S3" shape to actually work.

## Layout

```
24-retail-streaming-analytics/
├── terraform/               # 7 resources, one provider
├── tests/test_analytics.py  # 6 tests
└── scripts/{deploy,test,teardown}.sh, produce.py
```

## Requires

```sh
localemu start   # no special flags
```

## Running the test suite

```sh
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```

## Running the live demo

```sh
./scripts/deploy.sh local
python3 scripts/produce.py 50     # simulate 50 order events
# wait ~15s for Firehose's buffering_interval to flush
aws --endpoint-url=http://localhost:4566 athena start-query-execution \
  --query-string "SELECT event, COUNT(*), ROUND(SUM(amount),2) FROM retail_analytics_db.events GROUP BY event" \
  --result-configuration OutputLocation=s3://le-analytics-athena-results-us-east-1/
# then athena get-query-execution / get-query-results with the returned QueryExecutionId
./scripts/teardown.sh local
```
