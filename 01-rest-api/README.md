# 01-rest-api

A CRUD notes service: five HTTP routes on API Gateway v2 + Lambda + DynamoDB.

Runs end-to-end on LocalEmu. Same Terraform, same zip, same tests on real AWS
with a one-argument change.

## Layout

```
01-rest-api/
├── src/handler.py          # Five routes, one file, no framework
├── terraform/              # 13 resources
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── tests/
│   ├── conftest.py
│   └── test_api.py         # 3 tests, real HTTP
└── scripts/
    ├── deploy.sh
    ├── test.sh
    └── teardown.sh
```

## Running locally

```sh
localemu start                    # in another terminal
./scripts/deploy.sh    local
./scripts/test.sh      local
./scripts/teardown.sh  local
```
