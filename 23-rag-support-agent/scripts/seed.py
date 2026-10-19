#!/usr/bin/env python3
"""One-time setup after `terraform apply`: create the OpenSearch k-NN index
and seed the FAQ knowledge base + a couple of known orders.

The embedding dimension is derived from whatever LLMClient.embed() returns
(4 for the canned LLM_MODE=local vectors, 768/1536+ for a real model via
LLM_MODE=bedrock against LocalEmu's own Bedrock InvokeModel, or real AWS)
so this script works unmodified in either mode.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))

os.environ.setdefault("LLM_MODE", "local")
if os.environ.get("TARGET", "local") == "local":
    # LLM_MODE=bedrock builds a bedrock-runtime client; point it at LocalEmu.
    os.environ.setdefault("AWS_ENDPOINT_URL", "http://localhost:4566")
    os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
    os.environ.setdefault("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")
    os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
os.environ.setdefault("LLM_LOCAL_ANSWERS_PATH", str(HERE.parent / "src" / "local_answers.jsonl"))

from llm_client import get_client  # noqa: E402

FAQ_DOCS = [
    "Our return policy allows returns within 30 days of purchase with a valid receipt.",
    "We ship internationally to over 40 countries, with delivery times of 7-14 business days.",
    "Gift cards never expire and can be used for any purchase on our site.",
    "Our customer support team is available 24/7 via live chat and email.",
]

ORDERS = [
    {"order_id": "O-1001", "status": "SHIPPED"},
    {"order_id": "O-1002", "status": "PROCESSING"},
]


def _tf_output(name: str) -> str:
    out = subprocess.check_output(["terraform", "output", "-raw", name], cwd=str(HERE.parent / "terraform"))
    return out.decode().strip()


def _request(method: str, url: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def main() -> None:
    endpoint = _tf_output("opensearch_endpoint")
    index_name = os.environ.get("KB_INDEX", "faq-kb")
    orders_table = _tf_output("orders_table")

    llm = get_client()
    vectors = [llm.embed(doc) for doc in FAQ_DOCS]
    dim = len(vectors[0])
    print(f"embedding dimension: {dim}")

    # Drop a stale index first: one built with another embedding dimension
    # (canned 4-dim vs a real 768-dim model) would reject the new vectors.
    try:
        _request("DELETE", f"http://{endpoint}/{index_name}")
    except Exception:
        pass

    print(f"creating k-NN index {index_name!r} on {endpoint} ...")
    try:
        _request("PUT", f"http://{endpoint}/{index_name}", {
            "settings": {"index.knn": True},
            "mappings": {"properties": {
                "text": {"type": "text"},
                "embedding": {"type": "knn_vector", "dimension": dim},
            }},
        })
    except Exception as e:
        print(f"  (index create warning, continuing: {e})")

    for i, (doc, vector) in enumerate(zip(FAQ_DOCS, vectors), start=1):
        _request("PUT", f"http://{endpoint}/{index_name}/_doc/{i}", {"text": doc, "embedding": vector})
        print(f"  indexed doc {i}: {doc[:60]}...")

    import boto3

    ddb = boto3.resource(
        "dynamodb",
        endpoint_url=os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566"),
        region_name="us-east-1",
        aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
        aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    )
    table = ddb.Table(orders_table)
    for order in ORDERS:
        table.put_item(Item=order)
        print(f"  seeded order {order['order_id']} -> {order['status']}")

    print("done.")


if __name__ == "__main__":
    main()
