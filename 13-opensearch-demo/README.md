# 13-opensearch-demo

Full OpenSearch walkthrough on LocalEmu:

1. Create domain via the AWS API
2. Describe + show the Docker container LocalEmu spun up
3. Wait for cluster health (green/yellow)
4. Index 2 documents via HTTP
5. Full-text search (`match` on `description`)
6. Python client: re-index 3 products, run a match query, assert 2 hits
7. Delete the domain, verify Docker container is gone

Uses a real `opensearchproject/opensearch:2.11.1` container managed by
LocalEmu. Needs `OPENSEARCH_DOCKER_BACKEND=1` on the LocalEmu host (this
is the default in newer LocalEmu releases).

## Running

```sh
localemu start                    # in another terminal
pip install -r requirements.txt
./scripts/demo.sh
./scripts/teardown.sh
```
