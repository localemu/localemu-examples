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
  routes = {
    post_note   = "POST /notes"
    list_notes  = "GET /notes"
    get_note    = "GET /notes/{id}"
    update_note = "PATCH /notes/{id}"
    delete_note = "DELETE /notes/{id}"
  }
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
      apigateway   = local.endpoint
      apigatewayv2 = local.endpoint
      dynamodb     = local.endpoint
      iam          = local.endpoint
      lambda       = local.endpoint
      sts          = local.endpoint
      logs         = local.endpoint
    }
  }
}

# --------------------------- DYNAMODB (1) ---------------------------
resource "aws_dynamodb_table" "notes" {
  name         = "${var.prefix}-notes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "note_id"
  attribute {
    name = "note_id"
    type = "S"
  }
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
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
          "dynamodb:DeleteItem", "dynamodb:Scan",
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

# --------------------------- LAMBDA (1) ---------------------------
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
      TABLE_NAME = aws_dynamodb_table.notes.name
    }
  }
}

# --------------------------- API GATEWAY v2 (3 + 5 routes) ---------------------------
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

resource "aws_apigatewayv2_route" "r" {
  for_each  = local.routes
  api_id    = aws_apigatewayv2_api.api.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
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
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
