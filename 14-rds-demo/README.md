# 14-rds-demo

Spin up real PostgreSQL and MySQL databases through the RDS API. Each
`aws rds create-db-instance` launches an actual `postgres:16` or
`mysql:8.0` Docker container, maps it to a localhost port, and returns
the real endpoint.

The demo connects with `psql`, `mysql`, and Python (`psycopg2`,
`pymysql`) to prove it is a real database, not a mock.

## Requires

LocalEmu started with `RDS_DOCKER_BACKEND=1`:

```sh
RDS_DOCKER_BACKEND=1 localemu start
```

Without that flag, `create-db-instance` succeeds but returns an
AWS-shaped fake endpoint with no container underneath.

## Running

```sh
pip install -r requirements.txt
./scripts/demo.sh
./scripts/teardown.sh
```
