"""Retail support agent - real OpenSearch k-NN retrieval + real tool-calling.

Routing is a cheap, deterministic pre-router (a regex for an order id),
not an LLM call - a common, pragmatic agent pattern: reserve the LLM for
what actually needs language understanding (grounding an answer in
unstructured FAQ text), and keep structured-data lookups templated and
fast. Two paths:

  order-status question  -> check_order_status tool Lambda
                             (not found -> create_support_ticket tool Lambda)
  anything else           -> embed -> OpenSearch k-NN search over the FAQ
                             knowledge base -> generate a grounded answer

Both tool calls are real Lambda-to-Lambda `lambda:Invoke` calls, not
in-process function calls - the same mechanism a production
tool-calling agent uses to run an action.
"""
from __future__ import annotations

import json
import logging
import os
import re

import boto3

from llm_client import get_client

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

OPENSEARCH_ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"]
KB_INDEX = os.environ.get("KB_INDEX", "faq-kb")
CHECK_ORDER_STATUS_FUNCTION = os.environ["CHECK_ORDER_STATUS_FUNCTION"]
CREATE_TICKET_FUNCTION = os.environ["CREATE_TICKET_FUNCTION"]

_lambda = boto3.client("lambda")
_llm = get_client()

ORDER_ID_RE = re.compile(r"\b(O-\d{3,})\b", re.IGNORECASE)


def handle(event, _ctx):
    question = (event.get("question") or "").strip()
    if not question:
        return {"answer": None, "error": "missing_question"}

    order_match = ORDER_ID_RE.search(question)
    if order_match:
        return _handle_order_question(order_match.group(1).upper(), question)

    return _handle_kb_question(question)


def _invoke(function_name: str, payload: dict) -> dict:
    resp = _lambda.invoke(
        FunctionName=function_name,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode(),
    )
    return json.loads(resp["Payload"].read())


def _handle_order_question(order_id: str, question: str) -> dict:
    result = _invoke(CHECK_ORDER_STATUS_FUNCTION, {"order_id": order_id})

    if result.get("found"):
        status = result["status"]
        return {
            "answer": f"Order {order_id} is currently {status}.",
            "route": "check_order_status",
            "order_id": order_id,
            "status": status,
        }

    ticket = _invoke(
        CREATE_TICKET_FUNCTION,
        {"subject": f"Order {order_id} not found", "body": question},
    )
    return {
        "answer": (
            f"I couldn't find an order matching {order_id}. I've opened support "
            f"ticket {ticket['ticket_id']} so a human can look into it."
        ),
        "route": "check_order_status_then_create_ticket",
        "order_id": order_id,
        "ticket_id": ticket["ticket_id"],
    }


def _handle_kb_question(question: str) -> dict:
    query_vector = _llm.embed(question)
    hits = _knn_search(query_vector, k=1)

    if not hits:
        return {"answer": None, "route": "knowledge_base", "reason": "no_hits"}

    top_doc = hits[0]["_source"]["text"]
    prompt = (
        f"Context: {top_doc}\n\n"
        f"Question: {question}\n\n"
        "Answer the question using only the context above, in one sentence."
    )
    answer = _llm.generate(prompt)
    return {
        "answer": answer,
        "route": "knowledge_base",
        "retrieved_doc": top_doc,
        "retrieval_score": hits[0]["_score"],
    }


def _container_reachable_endpoint(endpoint: str) -> str:
    """OPENSEARCH_ENDPOINT is a *host*-mapped address (``localhost:<port>``) -
    reachable from your laptop, not from inside the agent Lambda's own
    Docker container (a peer container, not the host). Docker Desktop's
    ``host.docker.internal`` resolves to the host from inside any
    container, which routes back through the same port mapping - so this
    swap is all that's needed, no raw container IP required.
    """
    return endpoint.replace("localhost", "host.docker.internal").replace("127.0.0.1", "host.docker.internal")


def _knn_search(vector: list[float], *, k: int) -> list[dict]:
    import urllib.request

    endpoint = _container_reachable_endpoint(OPENSEARCH_ENDPOINT)
    body = json.dumps({"size": k, "query": {"knn": {"embedding": {"vector": vector, "k": k}}}}).encode()
    req = urllib.request.Request(
        f"http://{endpoint}/{KB_INDEX}/_search",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        parsed = json.loads(resp.read())
    return parsed.get("hits", {}).get("hits", [])
