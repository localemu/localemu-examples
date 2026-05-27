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
  s3_use_path_style           = local.is_local

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      apigateway     = local.endpoint
      apigatewayv2   = local.endpoint
      cloudwatch     = local.endpoint
      dynamodb       = local.endpoint
      events         = local.endpoint
      iam            = local.endpoint
      lambda         = local.endpoint
      sqs            = local.endpoint
      sts            = local.endpoint
    }
  }
}

# --------------------------- DYNAMODB TABLES (3) ---------------------------
resource "aws_dynamodb_table" "cache" {
  name         = "${var.prefix}-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cache_key"
  attribute {
    name = "cache_key"
    type = "S"
  }
}

resource "aws_dynamodb_table" "incidents" {
  name         = "${var.prefix}-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"
  range_key    = "stage"
  attribute {
    name = "request_id"
    type = "S"
  }
  attribute {
    name = "stage"
    type = "S"
  }
}

resource "aws_dynamodb_table" "scores" {
  name         = "${var.prefix}-scores"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"
  attribute {
    name = "request_id"
    type = "S"
  }
}

# --------------------------- SQS (2) ---------------------------
resource "aws_sqs_queue" "eval_dlq" {
  name = "${var.prefix}-eval-dlq"
}

resource "aws_sqs_queue" "eval" {
  name                       = "${var.prefix}-eval"
  visibility_timeout_seconds = 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.eval_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "eval_allow_events" {
  queue_url = aws_sqs_queue.eval.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action = "sqs:SendMessage"
      Resource = aws_sqs_queue.eval.arn
    }]
  })
}

# --------------------------- EVENTBRIDGE (3) ---------------------------
resource "aws_cloudwatch_event_bus" "bus" {
  name = "${var.prefix}-bus"
}

resource "aws_cloudwatch_event_rule" "answer_rule" {
  name           = "${var.prefix}-answer-rule"
  event_bus_name = aws_cloudwatch_event_bus.bus.name
  event_pattern = jsonencode({
    source      = ["llmgw.gateway"]
    detail-type = ["answer.generated"]
  })
}

resource "aws_cloudwatch_event_target" "to_sqs" {
  rule           = aws_cloudwatch_event_rule.answer_rule.name
  event_bus_name = aws_cloudwatch_event_bus.bus.name
  target_id      = "sqs-eval"
  arn            = aws_sqs_queue.eval.arn
}

# --------------------------- IAM (2) ---------------------------
resource "aws_iam_role" "lambda_role" {
  name = "${var.prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
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
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
          "dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan",
          "events:PutEvents",
          "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes",
          "cloudwatch:PutMetricData",
          "bedrock:InvokeModel",
        ]
        Resource = "*"
      },
    ]
  })
}

# --------------------------- LAMBDA PACKAGE ---------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/build/lambda.zip"
}

# --------------------------- LAMBDAS (2) ---------------------------
resource "aws_lambda_function" "gateway" {
  function_name    = "${var.prefix}-gateway"
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.11"
  handler          = "gateway.handle"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  memory_size      = 256
  environment {
    variables = {
      LLM_MODE          = var.llm_mode
      LLM_LOCAL_ANSWERS_PATH = "/var/task/local_answers.jsonl"
      CACHE_TABLE       = aws_dynamodb_table.cache.name
      INCIDENTS_TABLE   = aws_dynamodb_table.incidents.name
      EVENT_BUS_NAME    = aws_cloudwatch_event_bus.bus.name
      CACHE_THRESHOLD   = "0.93"
    }
  }
}

resource "aws_lambda_function" "judge" {
  function_name    = "${var.prefix}-judge"
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.11"
  handler          = "judge.handle"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  memory_size      = 256
  environment {
    variables = {
      LLM_MODE          = var.llm_mode
      LLM_LOCAL_ANSWERS_PATH = "/var/task/local_answers.jsonl"
      SCORES_TABLE      = aws_dynamodb_table.scores.name
      METRIC_NAMESPACE  = "LLMGateway"
      SAMPLE_RATE       = var.sample_rate
    }
  }
}

# --------------------------- LAMBDA EVENT SOURCE MAPPING (1) ---------------------------
resource "aws_lambda_event_source_mapping" "judge_sqs" {
  event_source_arn = aws_sqs_queue.eval.arn
  function_name    = aws_lambda_function.judge.arn
  batch_size       = 1
}

# --------------------------- API GATEWAY v2 (4) ---------------------------
resource "aws_apigatewayv2_api" "api" {
  name          = "${var.prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "gw_integration" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.gateway.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ask_route" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /ask"
  target    = "integrations/${aws_apigatewayv2_integration.gw_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

# --------------------------- LAMBDA PERMISSION (1) ---------------------------
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.gateway.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
