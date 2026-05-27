# 21-chaos-resilience

A resilient-writer Lambda **tested against real AWS failure modes**,
locally. The same Lambda, same load, same data set, run three
times against three different LocalEmu chaos configurations, and
watch the retry / backoff / latency-budget envelope hold up (or not).

The point: every team claims their retry logic works. With LocalEmu's
throttling and latency simulation, you can **actually prove it** in
the inner loop, no production incident required.

## The Lambda

`src/handler.py` does one idempotent `dynamodb:PutItem` per invocation
with explicit exponential-backoff retry on the AWS throttle codes:

- `ProvisionedThroughputExceededException` (DynamoDB)
- `ThrottlingException`, `Throttling`, `TooManyRequestsException`
- `RequestLimitExceeded`, `SlowDown`, `OverLimit`, `LimitExceededException`

Backoff: 100, 200, 400, 800, 1600 ms with 0–50% additive jitter.
`MAX_ATTEMPTS=5`. boto3's built-in retry layer is disabled so the
custom loop is the only one, so the retry counts reported are real.

Each invocation returns a structured envelope:

```json
{
  "ok": true,
  "request_id": "req-42",
  "attempts": 2,
  "throttled": 1,
  "elapsed_ms": 384.2,
  "total_backoff_ms": 134.7
}
```

## The load driver

`infra/02_load_test.sh` fires `REQUESTS=50` invocations with
`CONCURRENCY=10` via `xargs -P`. Each worker writes its JSON
response to `.state/responses/`. A small Python pass aggregates:

- ok / failed counts
- total throttle events observed
- sum of attempts (`= REQUESTS` if zero retries fired)
- latency p50 / p95 / p99
- final DynamoDB item count → **zero data loss** assertion

## The chaos matrix (verified)

Re-run `./scripts/demo.sh` against each LocalEmu configuration. The
demo is the same; what differs is what LocalEmu does to the requests
on the way in.

| LocalEmu config | requests | ok | failed | throttle events | sum(attempts) | p50 | p95 | p99 | data loss |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **calm-mode** (no flags) | 50 | 50 | 0 | 0 | 50 | 21 ms | 75 ms | 103 ms | 0 |
| `SIMULATE_THROTTLING=1`<br>`DYNAMODB_THROTTLE_RATE=0.3` | 50 | 50 | 0 | 26 | 76 | 14 ms | 513 ms | 980 ms | 0 |
| `SIMULATE_LATENCY=300` | 50 | 50 | 0 | 0 | 50 | 318 ms | 348 ms | 397 ms | 0 |

Read the table this way:

- **Calm-mode**: nothing surprising; 50 requests land in ~75ms p95.
- **30% DynamoDB throttle**: about 30% of put-item calls are rejected
  by LocalEmu with `ProvisionedThroughputExceededException`; the
  retry loop fires 26 extra attempts (76 attempts to land 50 items);
  p95 latency balloons from 75ms to 513ms (backoff sleeps); **zero
  data loss** because every retry eventually succeeds.
- **300 ms latency injection**: no throttles, no retries, but every
  request pays the latency; p50/p95/p99 all sit near 300ms with a
  tight spread.

The retry logic is doing the work it claims to do. The chaos config
is doing the work it claims to do. **Both visible from one demo.**

## Why this matters

> "Our service handles throttling."

Everyone says that. Most can't show it.

Real AWS doesn't let you turn on 30% DynamoDB throttling for one test
run. LocalEmu does. The chaos drill becomes an inner-loop affordance:
write the retry, verify it, ship it, repeat. The first time you'll
know your retry was broken is **in dev**, not at 3am during the next
hot-table incident.

## Requires

- LocalEmu running (any config; see chaos matrix above).
- `aws` CLI (v1 or v2), `python3`, `zip`, `xargs` (GNU or BSD both work).

## Running

```sh
# 1) Baseline (no chaos)
localemu start
./scripts/demo.sh

# 2) Throttle mode (restart LocalEmu first)
./scripts/teardown.sh
SIMULATE_THROTTLING=1 DYNAMODB_THROTTLE_RATE=0.3 localemu start
./scripts/demo.sh

# 3) Latency mode (restart LocalEmu first)
./scripts/teardown.sh
SIMULATE_LATENCY=300 localemu start
./scripts/demo.sh

# Cleanup
./scripts/teardown.sh
```

Override `REQUESTS` and `CONCURRENCY` from the environment if you
want a heavier shake:

```sh
REQUESTS=500 CONCURRENCY=50 ./scripts/demo.sh
```

## Layout

```
21-chaos-resilience/
├── README.md
├── scripts/
│   ├── demo.sh
│   └── teardown.sh
├── lib/
│   └── common.sh        <- awsx, logging, detect_chaos helper
├── src/
│   └── handler.py       <- the resilient writer: bounded retry + jitter
└── infra/
    ├── 01_setup.sh      <- DynamoDB table, IAM role, Lambda
    └── 02_load_test.sh  <- N concurrent invocations + summary + 0-loss assertion
```

## What this exercises in LocalEmu

- `SIMULATE_THROTTLING=1` + `<SERVICE>_THROTTLE_RATE=0.x`: randomized
  per-service throttle injection with AWS-real error codes
  (`ProvisionedThroughputExceededException`, `SlowDown`, ...).
- `SIMULATE_LATENCY=<ms>`: fixed per-request latency added at the
  gateway layer; per-service realistic profiles are also supported
  via `SIMULATE_LATENCY=1`.
- Lambda invocation under STS-derived session credentials when
  `IAM_ENFORCEMENT=1` (the demo works under enforcement; the writer
  Lambda's role grants only `dynamodb:PutItem` on the one table).
