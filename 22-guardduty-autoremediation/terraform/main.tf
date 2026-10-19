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
      guardduty = local.endpoint
      dynamodb  = local.endpoint
      events    = local.endpoint
      iam       = local.endpoint
      lambda    = local.endpoint
      sns       = local.endpoint
      sts       = local.endpoint
      logs      = local.endpoint
    }
  }
}

# --------------------------- GUARDDUTY (1) ---------------------------
resource "aws_guardduty_detector" "this" {
  enable = true
}

# --------------------------- "VICTIM" ROLE (2) ---------------------------
# Stand-in for an EC2 instance role whose credentials get phished (e.g. via
# the SSRF -> IMDS chain taught elsewhere in this workshop). GuardDuty's
# InstanceCredentialExfiltration finding names exactly this kind of role.
resource "aws_iam_role" "victim" {
  name = "${var.prefix}-victim-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
      {
        # In reality, the attacker never calls AssumeRole themselves — they
        # read these same temp creds off the compromised instance's IMDS
        # (see the SSRF -> IMDS lab). This second trust statement only
        # exists so scripts/attack.sh can mint an equivalent session
        # in-account to play that already-stolen-credential step locally.
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy" "victim_baseline" {
  name = "${var.prefix}-victim-baseline"
  role = aws_iam_role.victim.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket", "s3:ListAllMyBuckets"], Resource = "*" },
      { Effect = "Allow", Action = "sts:GetCallerIdentity", Resource = "*" },
    ]
  })
}

# --------------------------- DYNAMODB (1) ---------------------------
resource "aws_dynamodb_table" "incidents" {
  name         = "${var.prefix}-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "finding_id"
  attribute {
    name = "finding_id"
    type = "S"
  }
}

# --------------------------- SNS (1) ---------------------------
resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-alerts"
}

# --------------------------- IAM for responder Lambda (2) ---------------------------
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
        # Scoped by naming convention: the responder can only quarantine
        # identities that match this workshop's victim-resource prefix,
        # not arbitrary production roles/users.
        Effect = "Allow"
        Action = [
          "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:PutUserPolicy", "iam:DeleteUserPolicy",
          "iam:UpdateAccessKey", "iam:ListAccessKeys",
        ]
        Resource = [
          "arn:aws:iam::*:role/${var.prefix}-victim-*",
          "arn:aws:iam::*:user/${var.prefix}-victim-*",
        ]
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
  source_file = "${path.module}/../src/responder.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "responder" {
  function_name    = "${var.prefix}-responder"
  role             = aws_iam_role.lambda_role.arn
  handler          = "responder.handle"
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
resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${var.prefix}-on-guardduty-finding"
  description = "Auto-contain any identity GuardDuty flags for credential exfiltration or malicious recon."

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
  })
}

resource "aws_cloudwatch_event_target" "to_lambda" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "responder-lambda"
  arn       = aws_lambda_function.responder.arn
}

# --------------------------- LAMBDA PERMISSION (1) ---------------------------
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.responder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guardduty_findings.arn
}
