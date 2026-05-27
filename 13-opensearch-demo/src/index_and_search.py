"""Index a few products and run a full-text search.

Expects the OpenSearch endpoint (host:port) as argv[1], e.g.:
    python index_and_search.py localhost:49464
"""
from __future__ import annotations

import sys
import time

from opensearchpy import OpenSearch


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: index_and_search.py <host:port>", file=sys.stderr)
        return 2

    host, port = sys.argv[1].split(":")
    client = OpenSearch(hosts=[{"host": host, "port": int(port)}], use_ssl=False)

    # Wait briefly for the cluster to accept writes.
    for _ in range(20):
        try:
            client.cluster.health(wait_for_status="yellow", request_timeout=2)
            break
        except Exception:
            time.sleep(0.5)

    # (Re)create the index.
    if client.indices.exists(index="products"):
        client.indices.delete(index="products")
    client.indices.create(
        index="products",
        body={
            "mappings": {
                "properties": {
                    "name": {"type": "text"},
                    "price": {"type": "float"},
                    "description": {"type": "text"},
                    "category": {"type": "keyword"},
                }
            }
        },
    )

    products = [
        {"name": "MacBook Pro", "price": 2499, "description": "Apple laptop with M4 chip", "category": "laptops"},
        {"name": "ThinkPad X1", "price": 1899, "description": "Lenovo business laptop", "category": "laptops"},
        {"name": "AirPods Pro", "price": 249, "description": "Wireless earbuds with noise cancellation", "category": "audio"},
    ]
    for i, product in enumerate(products, start=1):
        client.index(index="products", id=i, body=product)
    client.indices.refresh(index="products")

    results = client.search(
        index="products",
        body={"query": {"match": {"description": "laptop"}}},
    )
    total = results["hits"]["total"]["value"]
    print(f"Full-text search for 'laptop' matched {total} documents:")
    for hit in results["hits"]["hits"]:
        print(f"  {hit['_source']['name']:<18} score={hit['_score']:.3f}")

    assert total == 2, f"expected 2 matches for 'laptop', got {total}"
    return 0


if __name__ == "__main__":
    sys.exit(main())
