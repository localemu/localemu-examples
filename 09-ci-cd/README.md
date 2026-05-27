# 09-ci-cd

A File Processing Service in Python with integration tests that run
against LocalEmu both on your laptop and in GitHub Actions CI. No AWS
credentials required in either place.

Three tests:
1. `test_process_file_writes_all_records`: 3-record JSON file lands 3
   rows in DynamoDB.
2. `test_process_file_handles_empty_records`: empty records array is a
   zero-write no-op.
3. `test_process_file_sets_source_file`: the `source_file` field on
   each row equals the S3 key of the input.

## Layout

```
09-ci-cd/
├── src/app.py
├── tests/conftest.py + test_app.py
├── requirements.txt
├── .github/workflows/test.yml       # GitHub Actions w/ localemu service
└── scripts/{test,teardown}.sh
```

## Running locally

```sh
localemu start                    # in another terminal
pip install -r requirements.txt
./scripts/test.sh
./scripts/teardown.sh             # optional, removes bucket + table
```

## Running in CI

Push to GitHub. The included workflow pulls
`localemu/localemu:latest` as a service container, waits for its
health-check, then runs `pytest tests/ -v`. No secrets required.
