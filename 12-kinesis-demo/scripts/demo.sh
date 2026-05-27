#!/usr/bin/env bash
# Full Kinesis walkthrough: CLI + Python. Each step prints real output.
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

HERE="$(cd "$(dirname "$0")/.." && pwd)"

bold() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

# Clean slate: drop any pre-existing 'my-stream' from a previous run.
aws $ENDPOINT kinesis delete-stream --stream-name my-stream 2>/dev/null || true

bold "1. Create stream my-stream (1 shard)"
aws $ENDPOINT kinesis create-stream --stream-name my-stream --shard-count 1
aws $ENDPOINT kinesis wait stream-exists --stream-name my-stream

bold "2. Describe stream (should be ACTIVE with 1 shard)"
aws $ENDPOINT kinesis describe-stream --stream-name my-stream \
  --query 'StreamDescription.{Name:StreamName, Status:StreamStatus, Shards:Shards[].ShardId}'

bold "3. Put 3 records (login, purchase, logout)"
# AWS CLI v1 sends --data as raw bytes; Kinesis returns it base64-encoded on read.
for payload in \
  '{"event":"login","user":"tarek"}' \
  '{"event":"purchase","user":"alice","amount":99.99}' \
  '{"event":"logout","user":"tarek"}'
do
  user=$(echo "$payload" | python3 -c 'import json,sys;print(json.load(sys.stdin)["user"])')
  resp=$(aws $ENDPOINT kinesis put-record \
    --stream-name my-stream \
    --partition-key "user-$user" \
    --data "$payload")
  seq=$(echo "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin)["SequenceNumber"])')
  echo "   seq=$seq payload=$payload"
done

bold "4. Get shard iterator + get records (decoded)"
SHARD_ID=$(aws $ENDPOINT kinesis describe-stream --stream-name my-stream \
  --query 'StreamDescription.Shards[0].ShardId' --output text)
ITER=$(aws $ENDPOINT kinesis get-shard-iterator --stream-name my-stream \
  --shard-id "$SHARD_ID" --shard-iterator-type TRIM_HORIZON \
  --query 'ShardIterator' --output text)

aws $ENDPOINT kinesis get-records --shard-iterator "$ITER" --limit 100 | python3 -c "
import base64, json, sys
resp = json.load(sys.stdin)
print(f'MillisBehindLatest: {resp[\"MillisBehindLatest\"]}')
for r in resp['Records']:
    data = json.loads(base64.b64decode(r['Data']))
    print(f'   seq={r[\"SequenceNumber\"]} pk={r[\"PartitionKey\"]} -> {data}')
"

bold "5. List streams"
aws $ENDPOINT kinesis list-streams --query 'StreamNames'

bold "6. Tag the stream"
aws $ENDPOINT kinesis add-tags-to-stream --stream-name my-stream \
  --tags env=dev,team=platform
aws $ENDPOINT kinesis list-tags-for-stream --stream-name my-stream \
  --query 'Tags[]' --output table

bold "7. Update shard count (1 -> 2, uniform scaling)"
aws $ENDPOINT kinesis update-shard-count \
  --stream-name my-stream \
  --target-shard-count 2 \
  --scaling-type UNIFORM_SCALING

bold "8. Python producer/consumer round-trip (asserts 3 payloads intact)"
python3 "$HERE/src/kinesis_demo.py"

bold "9. Delete my-stream"
aws $ENDPOINT kinesis delete-stream --stream-name my-stream

echo
echo "→ demo complete."
