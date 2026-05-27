"""S3 -> Lambda -> SNS + CloudWatch: thumbnail generator.

Triggered by s3:ObjectCreated:* on the incoming bucket. For each object,
fetches the bytes, scales to fit inside (THUMBNAIL_MAX_DIM, THUMBNAIL_MAX_DIM)
while preserving aspect ratio, writes to the processed bucket under
thumbnails/<original-key>, publishes a summary to SNS, and emits a
CloudWatch metric.
"""
from __future__ import annotations

import io
import json
import logging
import os

import boto3
from PIL import Image

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "LocalEmuImagePipeline")
THUMBNAIL_MAX = int(os.environ.get("THUMBNAIL_MAX_DIM", "128"))

_s3 = boto3.client("s3")
_sns = boto3.client("sns")
_cw = boto3.client("cloudwatch")


def handle(event, _ctx):
    results = []
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        try:
            summary = _process_one(bucket, key)
            results.append({"key": key, "ok": True, "summary": summary})
        except Exception as exc:
            LOG.exception("failed to process %s", key)
            results.append({"key": key, "ok": False, "error": str(exc)})
    return {"processed": len(results), "results": results}


def _process_one(bucket: str, key: str) -> dict:
    src_bytes = _s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    img = Image.open(io.BytesIO(src_bytes))
    fmt = img.format or "PNG"
    original = img.size
    img.thumbnail((THUMBNAIL_MAX, THUMBNAIL_MAX))

    out = io.BytesIO()
    img.save(out, format=fmt)
    thumb_bytes = out.getvalue()
    thumb_key = f"thumbnails/{key}"

    _s3.put_object(
        Bucket=PROCESSED_BUCKET,
        Key=thumb_key,
        Body=thumb_bytes,
        ContentType=f"image/{fmt.lower()}",
    )

    summary = {
        "source": {"bucket": bucket, "key": key, "width": original[0], "height": original[1]},
        "thumbnail": {"bucket": PROCESSED_BUCKET, "key": thumb_key, "width": img.size[0], "height": img.size[1]},
    }

    _sns.publish(TopicArn=SNS_TOPIC_ARN, Message=json.dumps(summary))
    _cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {"MetricName": "FilesProcessed", "Value": 1, "Unit": "Count"},
        ],
    )
    return summary
