# 12-kinesis-demo

End-to-end Kinesis Data Streams walkthrough on LocalEmu. Pure Python
backend, no Docker, no external process. Instant stream creation, real
shard iterators, sequence numbers, and a Python producer/consumer that
asserts payloads round-trip intact.

## Layout

```
12-kinesis-demo/
├── src/kinesis_demo.py      # producer + consumer in one script
└── scripts/{demo,teardown}.sh
```

## Running

```sh
localemu start                    # in another terminal
./scripts/demo.sh
./scripts/teardown.sh
```
