#!/usr/bin/env bash
# End-to-end OpenSearch walkthrough: create domain, verify Docker container,
# cluster health, index docs, full-text search, Python round-trip, delete.
set -euo pipefail

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
ENDPOINT="--endpoint-url=http://localhost:4566"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN=le-demo-search

bold() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

# If a prior run left the domain behind, drop it first.
aws $ENDPOINT opensearch delete-domain --domain-name "$DOMAIN" 2>/dev/null || true

bold "1. Create OpenSearch domain ($DOMAIN, engine=OpenSearch_2.11)"
aws $ENDPOINT opensearch create-domain \
  --domain-name "$DOMAIN" \
  --engine-version OpenSearch_2.11 \
  --query 'DomainStatus.{Name:DomainName,Version:EngineVersion,Endpoint:Endpoint}'

bold "2. Describe domain"
OS_ENDPOINT=$(aws $ENDPOINT opensearch describe-domain --domain-name "$DOMAIN" \
  --query 'DomainStatus.Endpoint' --output text)
echo "OpenSearch HTTP endpoint: $OS_ENDPOINT"

bold "3. Verify the Docker container is running"
docker ps --filter "label=localemu.service=opensearch" \
  --format 'table {{.Image}}\t{{.Status}}\t{{.Ports}}' | head -5

bold "4. Wait for cluster health to reach at least yellow"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s -m 2 "http://$OS_ENDPOINT/_cluster/health" | grep -q '"status":"\(green\|yellow\)"'; then
    break
  fi
  sleep 2
done
curl -s "http://$OS_ENDPOINT/_cluster/health" | python3 -c "
import json, sys
h = json.load(sys.stdin)
for k in ('cluster_name','status','number_of_nodes','active_primary_shards','active_shards'):
    print(f'  {k}: {h[k]}')
"

bold "5. Index two documents via HTTP"
curl -s -X PUT "http://$OS_ENDPOINT/products/_doc/1" \
  -H 'Content-Type: application/json' \
  -d '{"name":"MacBook Pro","price":2499,"description":"Apple laptop with M4 chip"}'
echo
curl -s -X PUT "http://$OS_ENDPOINT/products/_doc/2" \
  -H 'Content-Type: application/json' \
  -d '{"name":"ThinkPad X1","price":1899,"description":"Lenovo business laptop"}'
echo
curl -s -X POST "http://$OS_ENDPOINT/products/_refresh" >/dev/null

bold "6. Full-text search for 'laptop'"
curl -s "http://$OS_ENDPOINT/products/_search" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"match":{"description":"laptop"}}}' | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(f'  total hits: {r[\"hits\"][\"total\"][\"value\"]}')
for h in r['hits']['hits']:
    print(f'  id={h[\"_id\"]} score={h[\"_score\"]:.3f} name={h[\"_source\"][\"name\"]}')
"

bold "7. Python client: re-index 3 products, run match query, assert 2 hits"
python3 "$HERE/src/index_and_search.py" "$OS_ENDPOINT"

bold "8. Delete the domain (Docker container also torn down)"
aws $ENDPOINT opensearch delete-domain --domain-name "$DOMAIN" \
  --query 'DomainStatus.{Name:DomainName,Deleted:Deleted}'

sleep 2
if docker ps --filter "label=localemu.service=opensearch" --filter "name=localemu-opensearch-$DOMAIN" --format '{{.Names}}' | grep -q .; then
  echo "  WARNING: container still running"
else
  echo "  Docker container for $DOMAIN is gone"
fi

echo
echo "→ demo complete."
