"""Two integration tests: end-to-end pipeline + CloudWatch metric emitted."""
from __future__ import annotations

import io
import json
import uuid

from PIL import Image, ImageDraw

from conftest import wait_for


def _make_test_png(width: int = 512, height: int = 384) -> bytes:
    """A 512x384 PNG with four coloured quadrants."""
    img = Image.new("RGB", (width, height), "white")
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, width // 2, height // 2], fill="red")
    d.rectangle([width // 2, 0, width, height // 2], fill="green")
    d.rectangle([0, height // 2, width // 2, height], fill="blue")
    d.rectangle([width // 2, height // 2, width, height], fill="yellow")
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


def _download(s3, bucket: str, key: str) -> bytes | None:
    try:
        return s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    except s3.exceptions.NoSuchKey:
        return None


def test_pipeline_end_to_end(tf, s3, sns, sqs):
    # 1. Subscribe an ephemeral SQS queue to the topic so we can confirm SNS delivery.
    queue_name = f"le-images-test-{uuid.uuid4().hex[:8]}"
    q_url = sqs.create_queue(QueueName=queue_name)["QueueUrl"]
    q_arn = sqs.get_queue_attributes(QueueUrl=q_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    sqs.set_queue_attributes(
        QueueUrl=q_url,
        Attributes={
            "Policy": json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {"Service": "sns.amazonaws.com"},
                            "Action": "sqs:SendMessage",
                            "Resource": q_arn,
                            "Condition": {"ArnEquals": {"aws:SourceArn": tf["topic_arn"]}},
                        }
                    ],
                }
            )
        },
    )
    sns.subscribe(TopicArn=tf["topic_arn"], Protocol="sqs", Endpoint=q_arn)

    # 2. Upload a real 512x384 PNG to the incoming bucket.
    png = _make_test_png()
    test_key = f"images/test-{uuid.uuid4().hex[:8]}.png"
    s3.put_object(
        Bucket=tf["incoming_bucket"],
        Key=test_key,
        Body=png,
        ContentType="image/png",
    )

    # 3. Wait for the thumbnail to appear, re-open with Pillow to verify bytes are a valid image.
    thumb_key = f"thumbnails/{test_key}"
    thumb_bytes = wait_for(
        lambda: _download(s3, tf["processed_bucket"], thumb_key),
        timeout=60,
    )
    thumb = Image.open(io.BytesIO(thumb_bytes))
    thumb.verify()
    thumb = Image.open(io.BytesIO(thumb_bytes))  # verify() consumes; reopen to read size
    assert thumb.size == (128, 96)  # 4:3 preserved, max dim 128
    assert len(thumb_bytes) < len(png)

    # 4. Confirm the SNS notification arrived via our SQS subscriber.
    msgs = wait_for(
        lambda: sqs.receive_message(QueueUrl=q_url, MaxNumberOfMessages=1, WaitTimeSeconds=1).get("Messages"),
        timeout=30,
    )
    envelope = json.loads(msgs[0]["Body"])
    summary = json.loads(envelope["Message"])
    assert summary["source"]["width"] == 512
    assert summary["source"]["height"] == 384
    assert summary["thumbnail"]["width"] == 128
    assert summary["thumbnail"]["height"] == 96

    # cleanup ephemeral queue
    sqs.delete_queue(QueueUrl=q_url)


def test_cloudwatch_metric_emitted(tf, s3, cloudwatch):
    png = _make_test_png(width=256, height=256)
    test_key = f"images/metric-{uuid.uuid4().hex[:8]}.png"
    s3.put_object(
        Bucket=tf["incoming_bucket"],
        Key=test_key,
        Body=png,
        ContentType="image/png",
    )

    thumb_key = f"thumbnails/{test_key}"
    wait_for(lambda: _download(s3, tf["processed_bucket"], thumb_key), timeout=60)

    metrics = wait_for(
        lambda: cloudwatch.list_metrics(Namespace="LocalEmuImagePipeline")
        .get("Metrics")
        or None,
        timeout=30,
    )
    assert any(m["MetricName"] == "FilesProcessed" for m in metrics)
