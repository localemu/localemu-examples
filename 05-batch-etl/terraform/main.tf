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
      s3            = local.endpoint
      dynamodb      = local.endpoint
      lambda        = local.endpoint
      stepfunctions = local.endpoint
      iam           = local.endpoint
      sts           = local.endpoint
      logs          = local.endpoint
    }
  }
}

# --------------------------- S3 (1) ---------------------------
resource "aws_s3_bucket" "input" {
  bucket        = "${var.prefix}-input"
  force_destroy = true
}

# --------------------------- DYNAMODB (1) ---------------------------
resource "aws_dynamodb_table" "orders" {
  name         = "${var.prefix}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"
  attribute {
    name = "order_id"
    type = "S"
  }
}

# --------------------------- IAM: LAMBDA ROLE (2) ---------------------------
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
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.input.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.orders.arn
      },
    ]
  })
}

# --------------------------- IAM: STATE MACHINE ROLE (2) ---------------------------
resource "aws_iam_role" "sfn_role" {
  name = "${var.prefix}-sfn-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_policy" {
  name = "${var.prefix}-sfn-policy"
  role = aws_iam_role.sfn_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [
        aws_lambda_function.parse.arn,
        aws_lambda_function.load_row.arn,
      ]
    }]
  })
}

# --------------------------- LAMBDAS (2) ---------------------------
data "archive_file" "parse_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/parse.py"
  output_path = "${path.module}/build/parse.zip"
}

data "archive_file" "load_row_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/load_row.py"
  output_path = "${path.module}/build/load_row.zip"
}

resource "aws_lambda_function" "parse" {
  function_name    = "${var.prefix}-parse"
  role             = aws_iam_role.lambda_role.arn
  handler          = "parse.handle"
  runtime          = "python3.12"
  filename         = data.archive_file.parse_zip.output_path
  source_code_hash = data.archive_file.parse_zip.output_base64sha256
  timeout          = 15
}

resource "aws_lambda_function" "load_row" {
  function_name    = "${var.prefix}-load-row"
  role             = aws_iam_role.lambda_role.arn
  handler          = "load_row.handle"
  runtime          = "python3.12"
  filename         = data.archive_file.load_row_zip.output_path
  source_code_hash = data.archive_file.load_row_zip.output_base64sha256
  timeout          = 15
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.orders.name
    }
  }
}

# --------------------------- STEP FUNCTIONS (1) ---------------------------
resource "aws_sfn_state_machine" "etl" {
  name     = "${var.prefix}-etl"
  role_arn = aws_iam_role.sfn_role.arn

  definition = jsonencode({
    Comment = "Parse a CSV from S3, fan-out via Map, load each valid row into DynamoDB"
    StartAt = "Parse"
    States = {
      Parse = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.parse.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "rows.$" = "$.Payload.rows" }
        ResultPath     = "$.parsed"
        Next           = "LoadRows"
      }
      LoadRows = {
        Type           = "Map"
        ItemsPath      = "$.parsed.rows"
        MaxConcurrency = 5
        ResultPath     = "$.results"
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "LoadRow"
          States = {
            LoadRow = {
              Type     = "Task"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.load_row.arn
                "Payload.$"  = "$"
              }
              ResultSelector = { "result.$" = "$.Payload" }
              End            = true
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
                IntervalSeconds = 1
                MaxAttempts     = 2
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "RowFailed"
              }]
            }
            RowFailed = {
              Type   = "Pass"
              Result = { status = "rejected" }
              End    = true
            }
          }
        }
        End = true
      }
    }
  })
}
