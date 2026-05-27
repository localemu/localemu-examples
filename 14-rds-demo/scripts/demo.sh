#!/usr/bin/env bash
# End-to-end RDS walkthrough: spin up Postgres + MySQL containers via the
# RDS API, connect with real psql + mysql clients, run SQL, delete.
#
# Requires: LocalEmu started with RDS_DOCKER_BACKEND=1
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

HERE="$(cd "$(dirname "$0")/.." && pwd)"

bold() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

# Clean slate
aws $ENDPOINT rds delete-db-instance --db-instance-identifier my-postgres --skip-final-snapshot 2>/dev/null || true
aws $ENDPOINT rds delete-db-instance --db-instance-identifier my-mysql --skip-final-snapshot 2>/dev/null || true
sleep 2

bold "1. Create Postgres instance my-postgres"
aws $ENDPOINT rds create-db-instance \
  --db-instance-identifier my-postgres \
  --engine postgres \
  --master-username admin \
  --master-user-password Secret123 \
  --db-name myapp \
  --db-instance-class db.t3.micro \
  --allocated-storage 20 \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Endpoint:Endpoint}'

bold "2. Create MySQL instance my-mysql"
aws $ENDPOINT rds create-db-instance \
  --db-instance-identifier my-mysql \
  --engine mysql \
  --master-username root \
  --master-user-password Secret123 \
  --db-name shopdb \
  --db-instance-class db.t3.micro \
  --allocated-storage 20 \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Endpoint:Endpoint}'

bold "3. describe-db-instances"
aws $ENDPOINT rds describe-db-instances \
  --query 'DBInstances[].{Id:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Addr:Endpoint.Address,Port:Endpoint.Port}' \
  --output table

# Capture ports. The endpoint's Address field is an AWS-shaped hostname
# (matches what real AWS returns for compatibility), but the actual
# container is bound to localhost at the mapped port.
PG_PORT=$(aws $ENDPOINT rds describe-db-instances --db-instance-identifier my-postgres \
  --query 'DBInstances[0].Endpoint.Port' --output text)
MY_PORT=$(aws $ENDPOINT rds describe-db-instances --db-instance-identifier my-mysql \
  --query 'DBInstances[0].Endpoint.Port' --output text)
PG_ADDR=localhost
MY_ADDR=127.0.0.1
echo "   Postgres: $PG_ADDR:$PG_PORT"
echo "   MySQL:    $MY_ADDR:$MY_PORT"

bold "4. Verify Docker containers are running"
docker ps --filter "label=localemu.service=rds" \
  --format 'table {{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}'

bold "5. Wait for Postgres to accept connections"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if PGPASSWORD=Secret123 psql -h "$PG_ADDR" -p "$PG_PORT" -U admin -d myapp -tAc 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

bold "6. psql: version + CREATE TABLE + INSERT + SELECT"
PGPASSWORD=Secret123 psql -h "$PG_ADDR" -p "$PG_PORT" -U admin -d myapp <<'SQL'
SELECT version();
CREATE TABLE IF NOT EXISTS users (id serial PRIMARY KEY, name text, email text);
INSERT INTO users (name, email) VALUES ('Tarek', 'tarek@tocconsulting.fr');
SELECT * FROM users;
SQL

bold "7. Wait for MySQL to accept connections"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if mysql -h "$MY_ADDR" -P "$MY_PORT" -u root -pSecret123 -e 'SELECT 1' shopdb >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

bold "8. mysql: version + CREATE TABLE + INSERT + SELECT"
mysql -h "$MY_ADDR" -P "$MY_PORT" -u root -pSecret123 shopdb <<'SQL'
SELECT version();
CREATE TABLE IF NOT EXISTS products (id int AUTO_INCREMENT PRIMARY KEY, name varchar(100), price decimal(10,2));
INSERT INTO products (name, price) VALUES ('LocalEmu Pro', 0.00);
SELECT * FROM products;
SQL

bold "9. Python round-trip (psycopg2 + pymysql)"
python3 "$HERE/src/python_clients.py" "$PG_ADDR:$PG_PORT" "$MY_ADDR:$MY_PORT"

bold "10. Delete both instances"
aws $ENDPOINT rds delete-db-instance --db-instance-identifier my-postgres --skip-final-snapshot --query 'DBInstance.DBInstanceStatus' --output text
aws $ENDPOINT rds delete-db-instance --db-instance-identifier my-mysql    --skip-final-snapshot --query 'DBInstance.DBInstanceStatus' --output text
sleep 3

bold "11. Verify containers are gone"
if docker ps --filter "label=localemu.service=rds" --format '{{.Names}}' | grep -q .; then
  echo "  WARNING: some rds containers still running"
  docker ps --filter "label=localemu.service=rds" --format 'table {{.Image}}\t{{.Names}}'
else
  echo "  all rds containers gone"
fi

echo
echo "→ demo complete."
