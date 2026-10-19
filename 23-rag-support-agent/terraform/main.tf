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
}

provider "aws" {
  region                      = local.region
  access_key                  = local.is_local ? "AKIAIOSFODNN7EXAMPLE" : null
  secret_key                  = local.is_local ? "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" : null
  skip_credentials_validation = local.is_local
  skip_metadata_api_check     = local.is_local
  skip_requesting_account_id  = local.is_local

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      opensearch = local.endpoint
      dynamodb   = local.endpoint
      iam        = local.endpoint
      lambda     = local.endpoint
      bedrock    = local.endpoint
      sts        = local.endpoint
      logs       = local.endpoint
    }
  }
}

# --------------------------- OPENSEARCH (1) ---------------------------
resource "aws_opensearch_domain" "kb" {
  domain_name    = "${var.prefix}-kb"
  engine_version = "OpenSearch_2.11"
}

# --------------------------- DYNAMODB (2) ---------------------------
resource "aws_dynamodb_table" "orders" {
  name         = "${var.prefix}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"
  attribute {
    name = "order_id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "tickets" {
  name         = "${var.prefix}-tickets"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ticket_id"
  attribute {
    name = "ticket_id"
    type = "S"
  }
}

# --------------------------- IAM: tool lambdas (2 roles) ---------------------------
resource "aws_iam_role" "check_order_status_role" {
  name = "${var.prefix}-check-order-status-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "check_order_status_policy" {
  name = "${var.prefix}-check-order-status-policy"
  role = aws_iam_role.check_order_status_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" },
      { Effect = "Allow", Action = "dynamodb:GetItem", Resource = aws_dynamodb_table.orders.arn },
    ]
  })
}

resource "aws_iam_role" "create_ticket_role" {
  name = "${var.prefix}-create-ticket-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "create_ticket_policy" {
  name = "${var.prefix}-create-ticket-policy"
  role = aws_iam_role.create_ticket_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" },
      { Effect = "Allow", Action = "dynamodb:PutItem", Resource = aws_dynamodb_table.tickets.arn },
    ]
  })
}

# --------------------------- LAMBDA PACKAGE (shared by all 3 functions,
# same pattern as 08-llm-gateway: one zip, each function points its
# `handler` at a different file inside it). ---------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/build/lambda.zip"
}

# --------------------------- TOOL LAMBDAS (2) ---------------------------
resource "aws_lambda_function" "check_order_status" {
  function_name    = "${var.prefix}-check-order-status"
  role             = aws_iam_role.check_order_status_role.arn
  handler          = "check_order_status.handle"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 10
  environment {
    variables = { ORDERS_TABLE = aws_dynamodb_table.orders.name }
  }
}

resource "aws_lambda_function" "create_ticket" {
  function_name    = "${var.prefix}-create-ticket"
  role             = aws_iam_role.create_ticket_role.arn
  handler          = "create_support_ticket.handle"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 10
  environment {
    variables = { TICKETS_TABLE = aws_dynamodb_table.tickets.name }
  }
}

# --------------------------- IAM: agent lambda (1 role) ---------------------------
resource "aws_iam_role" "agent_role" {
  name = "${var.prefix}-agent-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "agent_policy" {
  name = "${var.prefix}-agent-policy"
  role = aws_iam_role.agent_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = [aws_lambda_function.check_order_status.arn, aws_lambda_function.create_ticket.arn]
      },
      { Effect = "Allow", Action = "bedrock-runtime:InvokeModel", Resource = "*" },
    ]
  })
}

# --------------------------- AGENT LAMBDA (1) ---------------------------
resource "aws_lambda_function" "agent" {
  function_name    = "${var.prefix}-agent"
  role             = aws_iam_role.agent_role.arn
  handler          = "agent.handle"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 120
  memory_size      = 256
  environment {
    variables = {
      OPENSEARCH_ENDPOINT         = aws_opensearch_domain.kb.endpoint
      KB_INDEX                    = "faq-kb"
      CHECK_ORDER_STATUS_FUNCTION = aws_lambda_function.check_order_status.function_name
      CREATE_TICKET_FUNCTION      = aws_lambda_function.create_ticket.function_name
      LLM_MODE                    = var.llm_mode
      LLM_LOCAL_ANSWERS_PATH      = "/var/task/local_answers.jsonl"
    }
  }
}
