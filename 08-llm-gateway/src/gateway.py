"""Gateway Lambda: five stages, one request.

Stages: input guardrail → semantic cache lookup → generate → output guardrail
        → cache write + eval event emit.

The _llm/_cache/_incidents/_events module-scope singletons are the DI wiring:
they run once per cold start and are reused across warm invocations.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import uuid

import boto3
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer

from llm_client import cosine, get_client

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

# -------- module scope: one-time cold-start wiring --------
_llm = get_client()

_ddb = boto3.client("dynamodb")
_events = boto3.client("events")

CACHE_TABLE = os.environ["CACHE_TABLE"]
INCIDENTS_TABLE = os.environ["INCIDENTS_TABLE"]
EVENT_BUS_NAME = os.environ["EVENT_BUS_NAME"]
CACHE_THRESHOLD = float(os.environ.get("CACHE_THRESHOLD", "0.93"))

_to_attr = TypeSerializer().serialize
_from_attr = TypeDeserializer().deserialize


def _to_item(d: dict) -> dict:
    return {k: _to_attr(v) for k, v in d.items()}


def _from_item(item: dict) -> dict:
    return {k: _from_attr(v) for k, v in item.items()}


def _resp(status: int, body: dict) -> dict:
    return {"statusCode": status, "headers": {"content-type": "application/json"}, "body": json.dumps(body)}


def query_digest(text: str) -> str:
    return hashlib.sha256(text.strip().lower().encode()).hexdigest()


def _log_incident(*, request_id: str, stage: str, text: str, reason: str) -> None:
    _ddb.put_item(
        TableName=INCIDENTS_TABLE,
        Item=_to_item(
            {
                "request_id": request_id,
                "stage": stage,
                "text": text[:500],
                "reason": reason,
            }
        ),
    )


def _cache_lookup(query_embedding: list[float]) -> dict | None:
    """Top-1 cosine over the cache table. Tutorial-scale scan."""
    page = _ddb.scan(TableName=CACHE_TABLE)
    best: dict | None = None
    best_sim = -1.0
    for raw in page.get("Items", []):
        item = _from_item(raw)
        cached_embedding = [float(x) for x in item["embedding"]]
        sim = cosine(query_embedding, cached_embedding)
        if sim > best_sim:
            best_sim = sim
            best = item
    if best is None or best_sim < CACHE_THRESHOLD:
        return None
    return {"item": best, "similarity": best_sim}


def _emit_eval_event(request_id: str, question: str, answer: str) -> None:
    detail = {"request_id": request_id, "question": question, "answer": answer, "refused": False}
    _events.put_events(
        Entries=[
            {
                "Source": "llmgw.gateway",
                "DetailType": "answer.generated",
                "Detail": json.dumps(detail),
                "EventBusName": EVENT_BUS_NAME,
            }
        ]
    )


def handle(event, _ctx):
    body = json.loads(event.get("body") or "{}")
    question = (body.get("question") or "").strip()
    request_id = uuid.uuid4().hex
    LOG.info("gateway: request_id=%s question=%r", request_id, question)

    if not question:
        LOG.info("gateway: request_id=%s response=400 reason=missing_question", request_id)
        return _resp(400, {"error": "missing 'question'", "request_id": request_id})

    # ---- Stage 1: INPUT GUARDRAIL ----
    in_check = _llm.classify(question, rubric="input_guardrail")
    LOG.info("gateway: request_id=%s stage=input_guardrail flagged=%s reason=%s",
             request_id, in_check["flagged"], in_check.get("reason"))
    if in_check["flagged"]:
        _log_incident(request_id=request_id, stage="input_guardrail", text=question, reason=in_check["reason"])
        LOG.info("gateway: request_id=%s response=400 reason=%s", request_id, in_check["reason"])
        return _resp(400, {"error": "blocked by input guardrail", "reason": in_check["reason"], "request_id": request_id})

    # ---- Stage 2: SEMANTIC CACHE LOOKUP ----
    embedding = _llm.embed(question)
    hit = _cache_lookup(embedding)
    if hit:
        sim = round(hit["similarity"], 4)
        LOG.info("gateway: request_id=%s stage=cache hit=true similarity=%s", request_id, sim)
        return _resp(
            200,
            {
                "answer": hit["item"]["answer"],
                "cache_hit": True,
                "similarity": sim,
                "request_id": request_id,
            },
        )
    LOG.info("gateway: request_id=%s stage=cache hit=false", request_id)

    # ---- Stage 3: GENERATE ----
    answer = _llm.generate(question)
    LOG.info("gateway: request_id=%s stage=generate answer_chars=%d", request_id, len(answer))

    # ---- Stage 4: OUTPUT GUARDRAIL ----
    out_check = _llm.classify(answer, rubric="output_guardrail")
    LOG.info("gateway: request_id=%s stage=output_guardrail flagged=%s reason=%s",
             request_id, out_check["flagged"], out_check.get("reason"))
    if out_check["flagged"]:
        _log_incident(request_id=request_id, stage="output_guardrail", text=answer, reason=out_check["reason"])
        # Refusals are deliberately NOT cached: a transient misfire must not
        # poison the cache forever.
        LOG.info("gateway: request_id=%s response=200 refused=true reason=%s",
                 request_id, out_check["reason"])
        return _resp(
            200,
            {"answer": "I can't help with that, policy violation.", "refused": True, "reason": out_check["reason"], "request_id": request_id},
        )

    # ---- Stage 5: CACHE WRITE + EMIT EVAL EVENT ----
    _ddb.put_item(
        TableName=CACHE_TABLE,
        Item=_to_item(
            {
                "cache_key": query_digest(question),
                "question": question,
                "answer": answer,
                "embedding": [str(x) for x in embedding],
            }
        ),
    )
    _emit_eval_event(request_id, question, answer)
    LOG.info("gateway: request_id=%s response=200 cache_hit=false answered=true", request_id)
    return _resp(200, {"answer": answer, "cache_hit": False, "request_id": request_id})
