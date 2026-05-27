# 20-stepfunctions-saga

A Step Functions **saga** with cascading compensations, exercised
under three injected failure scenarios. Each failure is caught by
ASL `Catch` and jumps to the compensation for the previous successful
step, which then chains down to release every side-effect that was
applied.

LocalEmu has a real Step Functions execution engine (not a CRUD-only
mock), which is what makes this pattern testable locally in seconds
instead of paying real-AWS execution costs and IAM propagation delays.

## Topology

```
              ReserveInventory ──► ChargePayment ──► CreateShipment ──► SendNotification
                    │                  │                  │                   │
                    │ catch            │ catch            │ catch             │ catch
                    ▼                  ▼                  ▼                   ▼
              FailHandler      CompensateReserve  CompensateCharge    CompensateShip
                                       ▲                  │                   │
                                       │                  ▼                   ▼
                                       └────────  CompensateReserve   CompensateCharge
                                                                              │
                                                                              ▼
                                                                      CompensateReserve
                                                                              │
                                                                              ▼
                                                                        FailHandler
```

Each forward step writes one row to a DynamoDB table (inventory,
payments, shipments) or publishes one SNS message (notifications).
Each compensation deletes the corresponding row. The final SNS step
has no compensation: it's the last forward action.

## What the run proves

| Scenario              | Expected execution status | Expected end state |
|-----------------------|--------------------------:|--------------------|
| `fail_at=` (happy)    | `SUCCEEDED`               | all 3 tables hold the order |
| `fail_at=charge`      | `FAILED`                  | inventory empty, payments empty, shipments empty |
| `fail_at=ship`        | `FAILED`                  | inventory empty, payments empty, shipments empty |
| `fail_at=notify`      | `FAILED`                  | inventory empty, payments empty, shipments empty |

All four scenarios verified end-to-end. Total runtime ~30 s.

## Fault-injection mechanism

A single Lambda handler is deployed seven times. Each instance reads
`STEP_NAME` from its environment to pick its branch of behavior. When
the event includes `"fail_at": "<step>"` and `STEP_NAME` matches, the
handler raises `RuntimeError`. The ASL `Catch` on each Task state
captures `States.ALL` and jumps to the appropriate compensation chain.

This is faster and cleaner than mocking per-test: production code
shape is preserved, only one input flag changes between runs.

## Requires

- LocalEmu running (no special flags needed; IAM_ENFORCEMENT=1 is
  supported and tested):

  ```sh
  localemu start
  ```

- `aws` CLI (v1 or v2), `python3`, `zip`.

## Running

```sh
./scripts/demo.sh       # setup + happy path + 3 fault scenarios, ~30 s
./scripts/teardown.sh   # clean up
```

Each phase is also runnable on its own:

```sh
./infra/01_setup.sh         # tables, topic, roles, 7 Lambdas, state machine
./infra/02_happy_path.sh    # invoke, expect SUCCEEDED, assert all 3 tables hold the order
./infra/03_fault_inject.sh  # 3 failure scenarios, each must compensate cleanly
./scripts/teardown.sh
```

Ids from step 01 are written to `.state/ids.env`; later steps source
that file.

## Layout

```
20-stepfunctions-saga/
├── README.md
├── scripts/
│   ├── demo.sh             <- orchestrator
│   └── teardown.sh
├── lib/
│   └── common.sh           <- awsx wrapper, start_and_wait, ddb_has helpers
├── src/
│   └── handler.py          <- single handler, dispatch on STEP_NAME env
└── infra/
    ├── 01_setup.sh         <- provision tables, topic, roles, Lambdas, state machine
    ├── 02_happy_path.sh    <- assert all forward steps land their writes
    └── 03_fault_inject.sh  <- 3 scenarios × cascading-compensation matrix
```

## What this exercises in LocalEmu

- `stepfunctions:CreateStateMachine` and `start-execution` with a
  real ASL definition (`Catch` + `ResultPath` per state).
- Full asynchronous execution loop: the state machine actually
  invokes each Lambda, captures the error envelope, and routes to the
  next state.
- `lambda:CreateFunction` × 7 (one handler, seven STEP_NAME wirings)
  with explicit IAM role and resource-scoped policies.
- `dynamodb:PutItem` / `DeleteItem` from inside a Lambda, evaluated
  under STS-derived session credentials when `IAM_ENFORCEMENT=1`.
- `sns:Publish` from a Lambda to a topic the role explicitly grants.
- `describe-execution` polling until the status leaves `RUNNING`.
