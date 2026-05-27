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
      apigatewayv2 = local.endpoint
      dynamodb     = local.endpoint
      events       = local.endpoint
      iam          = local.endpoint
      lambda       = local.endpoint
      sqs          = local.endpoint
      sts          = local.endpoint
      logs         = local.endpoint
    }
  }
}

# --------------------------- DYNAMODB (3) ---------------------------
resource "aws_dynamodb_table" "accounts" {
  name         = "${var.prefix}-accounts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "account_id"
  attribute {
    name = "account_id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "ledger" {
  name         = "${var.prefix}-ledger"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tx_id"
  range_key    = "leg"
  attribute {
    name = "tx_id"
    type = "S"
  }
  attribute {
    name = "leg"
    type = "S"
  }
}

resource "aws_dynamodb_table" "idempotency" {
  name         = "${var.prefix}-idempotency"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "key"
  attribute {
    name = "key"
    type = "S"
  }
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

# --------------------------- EVENTBRIDGE (3) ---------------------------
resource "aws_cloudwatch_event_bus" "bus" {
  name = "${var.prefix}-bus"
}

resource "aws_cloudwatch_event_rule" "settled" {
  name           = "${var.prefix}-on-settled"
  event_bus_name = aws_cloudwatch_event_bus.bus.name
  event_pattern = jsonencode({
    source      = ["pay.ledger"]
    detail-type = ["payment.settled"]
  })
}

resource "aws_cloudwatch_event_target" "to_sqs" {
  rule           = aws_cloudwatch_event_rule.settled.name
  event_bus_name = aws_cloudwatch_event_bus.bus.name
  target_id      = "sqs-settled"
  arn            = aws_sqs_queue.settled.arn
}

# --------------------------- SQS (2) ---------------------------
resource "aws_sqs_queue" "settled" {
  name                       = "${var.prefix}-settled-events"
  visibility_timeout_seconds = 30
}

resource "aws_sqs_queue_policy" "settled_allow_events" {
  queue_url = aws_sqs_queue.settled.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.settled.arn
    }]
  })
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
          "dynamodb:TransactWriteItems", "dynamodb:GetItem",
          "dynamodb:UpdateItem", "dynamodb:PutItem",
        ]
        Resource = [
          aws_dynamodb_table.accounts.arn,
          aws_dynamodb_table.ledger.arn,
          aws_dynamodb_table.idempotency.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.bus.arn
      },
    ]
  })
}

# --------------------------- LAMBDA + PERMISSION (2) ---------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/handler.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.prefix}-api"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.handle"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 15
  memory_size      = 256
  environment {
    variables = {
      ACCOUNTS_TABLE    = aws_dynamodb_table.accounts.name
      LEDGER_TABLE      = aws_dynamodb_table.ledger.name
      IDEMPOTENCY_TABLE = aws_dynamodb_table.idempotency.name
      EVENT_BUS_NAME    = aws_cloudwatch_event_bus.bus.name
    }
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# --------------------------- API GATEWAY v2 (4) ---------------------------
resource "aws_apigatewayv2_api" "api" {
  name          = "${var.prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_payments" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /payments"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}
