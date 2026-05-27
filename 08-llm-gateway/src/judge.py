"""Judge Lambda: async LLM-as-judge, triggered by SQS.

Samples non-refused responses, scores them against a rubric, writes the score
to DynamoDB, publishes a CloudWatch metric you can alarm on.
"""
from __future__ import annotations

import json
import logging
import os
import random

import boto3
from boto3.dynamodb.types import TypeSerializer

from llm_client import get_client

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

# -------- module scope: one-time cold-start wiring --------
_llm = get_client()

_ddb = boto3.client("dynamodb")
_cw = boto3.client("cloudwatch")

SCORES_TABLE = os.environ["SCORES_TABLE"]
METRIC_NS = os.environ.get("METRIC_NAMESPACE", "LLMGateway")
SAMPLE_RATE = float(os.environ.get("SAMPLE_RATE", "1.0"))

_to_attr = TypeSerializer().serialize


def _to_item(d: dict) -> dict:
    return {k: _to_attr(v) for k, v in d.items()}


def handle(event, _ctx):
    records = event.get("Records", [])
    LOG.info("judge: received batch of %d record(s)", len(records))
    scored = skipped_refused = skipped_sample = 0
    for record in records:
        body = json.loads(record["body"])
        # EventBridge → SQS: the SQS body IS the EventBridge envelope, detail is nested.
        detail = body.get("detail") or body
        request_id = detail.get("request_id", "?")

        if detail.get("refused"):
            LOG.info("judge: request_id=%s skipped reason=refused", request_id)
            skipped_refused += 1
            continue
        if random.random() > SAMPLE_RATE:
            LOG.info("judge: request_id=%s skipped reason=sample_rate", request_id)
            skipped_sample += 1
            continue

        verdict = _llm.judge(
            query=detail["question"],
            response=detail["answer"],
            rubric="helpfulness_accuracy",
        )
        LOG.info("judge: request_id=%s scored score=%s rubric=%s",
                 request_id, verdict["score"], verdict["rubric"])

        _ddb.put_item(
            TableName=SCORES_TABLE,
            Item=_to_item(
                {
                    "request_id": detail["request_id"],
                    "score": str(verdict["score"]),
                    "rubric": verdict["rubric"],
                    "question": detail["question"],
                }
            ),
        )
        scored += 1

        # CloudWatch is best-effort; DynamoDB is the source of truth.
        try:
            _cw.put_metric_data(
                Namespace=METRIC_NS,
                MetricData=[
                    {
                        "MetricName": "LLMQualityScore",
                        "Value": float(verdict["score"]),
                        "Dimensions": [{"Name": "Gateway", "Value": "default"}],
                    }
                ],
            )
        except Exception:
            LOG.exception("judge: request_id=%s PutMetricData failed, score is still in DynamoDB",
                          request_id)

    LOG.info("judge: batch done scored=%d skipped_refused=%d skipped_sample=%d",
             scored, skipped_refused, skipped_sample)
