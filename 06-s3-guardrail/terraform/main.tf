terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

locals {
  is_local = var.target == "local"
  endpoint = "http://localhost:4566"
  region   = "us-east-1"
  # A stable fake account id for the local target so the bucket policy below
  # can reference it; on AWS we pick the caller identity at plan time.
  account_id = local.is_local ? "000000000000" : data.aws_caller_identity.current[0].account_id
}

provider "aws" {
  region                      = local.region
  access_key                  = local.is_local ? "AKIAIOSFODNN7EXAMPLE" : null
  secret_key                  = local.is_local ? "test" : null
  skip_credentials_validation = local.is_local
  skip_metadata_api_check     = local.is_local
  skip_requesting_account_id  = local.is_local
  s3_use_path_style           = local.is_local

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      s3         = local.endpoint
      cloudtrail = local.endpoint
      dynamodb   = local.endpoint
      events     = local.endpoint
      iam        = local.endpoint
      lambda     = local.endpoint
      sns        = local.endpoint
      sts        = local.endpoint
      logs       = local.endpoint
    }
  }
}

data "aws_caller_identity" "current" {
  count = local.is_local ? 0 : 1
}

# --------------------------- DYNAMODB (1) ---------------------------
resource "aws_dynamodb_table" "incidents" {
  name         = "${var.prefix}-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"
  attribute {
    name = "event_id"
    type = "S"
  }
}

# --------------------------- SNS (1) ---------------------------
resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-alerts"
}

# --------------------------- CLOUDTRAIL (3: bucket + policy + trail) ---------------------------
resource "aws_s3_bucket" "trail" {
  bucket        = "${var.prefix}-trail-${local.region}"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/${local.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })
}

resource "aws_cloudtrail" "trail" {
  name                          = "${var.prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true
  depends_on                    = [aws_s3_bucket_policy.trail]
}

# --------------------------- IAM (2) ---------------------------
resource "aws_iam_role" "lambda_role" {
  name = "${var.prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.prefix}-lambda-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:HeadBucket", "s3:GetBucketAcl", "s3:GetBucketPolicyStatus",
          "s3:GetPublicAccessBlock", "s3:PutPublicAccessBlock",
          "s3:PutBucketTagging",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.incidents.arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
      },
    ]
  })
}

# --------------------------- LAMBDA (1) ---------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/handler.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "remediator" {
  function_name    = "${var.prefix}-remediator"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.handle"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 15
  memory_size      = 256
  environment {
    variables = {
      INCIDENTS_TABLE  = aws_dynamodb_table.incidents.name
      ALERTS_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
}

# --------------------------- EVENTBRIDGE (2) ---------------------------
resource "aws_cloudwatch_event_rule" "s3_policy_changes" {
  name        = "${var.prefix}-on-s3-policy-change"
  description = "Auto-remediate any S3 bucket whose access surface just widened."

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName = [
        "CreateBucket",
        "PutBucketAcl",
        "PutBucketPolicy",
        "PutBucketPublicAccessBlock",
        "DeletePublicAccessBlock",
        "DeleteBucketPublicAccessBlock",
        "PutBucketWebsite",
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "to_lambda" {
  rule      = aws_cloudwatch_event_rule.s3_policy_changes.name
  target_id = "guardrail-lambda"
  arn       = aws_lambda_function.remediator.arn
}

# --------------------------- LAMBDA PERMISSION (1) ---------------------------
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_policy_changes.arn
}
