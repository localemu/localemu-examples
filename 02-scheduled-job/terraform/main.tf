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
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = local.is_local ? "AKIAIOSFODNN7EXAMPLE" : null
  secret_key                  = local.is_local ? "test" : null
  skip_credentials_validation = local.is_local
  skip_metadata_api_check     = local.is_local
  skip_requesting_account_id  = local.is_local

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      dynamodb       = local.endpoint
      iam            = local.endpoint
      lambda         = local.endpoint
      scheduler      = local.endpoint
      secretsmanager = local.endpoint
      sts            = local.endpoint
      logs           = local.endpoint
    }
  }
}

# --------------------------- DYNAMODB (1) ---------------------------
resource "aws_dynamodb_table" "audit" {
  name         = "${var.prefix}-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "secret_name"
  range_key    = "run_id"
  attribute {
    name = "secret_name"
    type = "S"
  }
  attribute {
    name = "run_id"
    type = "S"
  }
}

# --------------------------- SECRETS (6: 3 secrets + 3 versions) ---------------------------
resource "aws_secretsmanager_secret" "fresh" {
  name                    = "${var.prefix}-fresh"
  recovery_window_in_days = 0
  tags                    = { Managed = "true" }
}

resource "aws_secretsmanager_secret_version" "fresh" {
  secret_id     = aws_secretsmanager_secret.fresh.id
  secret_string = "fresh-value"
}

resource "aws_secretsmanager_secret" "stale" {
  name                    = "${var.prefix}-stale"
  recovery_window_in_days = 0
  tags                    = { Managed = "true" }
}

resource "aws_secretsmanager_secret_version" "stale" {
  secret_id     = aws_secretsmanager_secret.stale.id
  secret_string = "stale-value"
}

resource "aws_secretsmanager_secret" "ignored" {
  name                    = "${var.prefix}-ignored"
  recovery_window_in_days = 0
  tags                    = { Managed = "false" }
}

resource "aws_secretsmanager_secret_version" "ignored" {
  secret_id     = aws_secretsmanager_secret.ignored.id
  secret_string = "ignored-value"
}

# --------------------------- IAM FOR LAMBDA (2) ---------------------------
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
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
        "dynamodb:PutItem", "dynamodb:Query", "dynamodb:Scan",
        "secretsmanager:ListSecrets", "secretsmanager:DescribeSecret",
      ]
      Resource = "*"
    }]
  })
}

# --------------------------- IAM FOR SCHEDULER (2) ---------------------------
resource "aws_iam_role" "scheduler_role" {
  name = "${var.prefix}-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name = "${var.prefix}-scheduler-policy"
  role = aws_iam_role.scheduler_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = "*"
    }]
  })
}

# --------------------------- LAMBDA PACKAGE + FUNCTION (1) ---------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "check" {
  function_name    = "${var.prefix}-check"
  role             = aws_iam_role.lambda_role.arn
  handler          = "rotation_check.handle"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 15
  memory_size      = 256
  environment {
    variables = {
      TABLE_NAME   = aws_dynamodb_table.audit.name
      MAX_AGE_DAYS = "30"
    }
  }
}

# --------------------------- SCHEDULER (1) ---------------------------
resource "aws_scheduler_schedule" "hourly" {
  name                         = "${var.prefix}-hourly"
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.check.arn
    role_arn = aws_iam_role.scheduler_role.arn
    input    = jsonencode({ source = "eventbridge-scheduler" })
  }
}
