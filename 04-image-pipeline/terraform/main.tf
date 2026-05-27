terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

locals {
  is_local = var.target == "local"
  endpoint = "http://localhost:4566"
}

provider "aws" {
  region                      = "us-east-1"
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
      lambda     = local.endpoint
      sns        = local.endpoint
      cloudwatch = local.endpoint
      iam        = local.endpoint
      sts        = local.endpoint
      logs       = local.endpoint
    }
  }
}

# --------------------------- S3 (2) ---------------------------
resource "aws_s3_bucket" "incoming" {
  bucket        = "${var.prefix}-incoming"
  force_destroy = true
}

resource "aws_s3_bucket" "processed" {
  bucket        = "${var.prefix}-processed"
  force_destroy = true
}

# --------------------------- SNS (1) ---------------------------
resource "aws_sns_topic" "notifications" {
  name = "${var.prefix}-notifications"
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
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "${aws_s3_bucket.incoming.arn}/*",
          "${aws_s3_bucket.processed.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.notifications.arn
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
      },
    ]
  })
}

# --------------------------- LAMBDA (1) ---------------------------
# build/lambda.zip is produced by scripts/build.sh (run via deploy.sh).
resource "aws_lambda_function" "processor" {
  function_name    = "${var.prefix}-processor"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.handle"
  runtime          = "python3.12"
  filename         = "${path.module}/../build/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/lambda.zip")
  timeout          = 30
  memory_size      = 512
  environment {
    variables = {
      PROCESSED_BUCKET  = aws_s3_bucket.processed.id
      SNS_TOPIC_ARN     = aws_sns_topic.notifications.arn
      METRIC_NAMESPACE  = "LocalEmuImagePipeline"
      THUMBNAIL_MAX_DIM = "128"
    }
  }
}

# --------------------------- LAMBDA PERMISSION + S3 TRIGGER (2) ---------------------------
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.incoming.arn
}

resource "aws_s3_bucket_notification" "incoming" {
  bucket = aws_s3_bucket.incoming.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".png"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpg"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpeg"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
