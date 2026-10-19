terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
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
  s3_use_path_style           = local.is_local

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
      s3       = local.endpoint
      firehose = local.endpoint
      glue     = local.endpoint
      athena   = local.endpoint
      iam      = local.endpoint
      sts      = local.endpoint
    }
  }
}

# --------------------------- S3 (2) ---------------------------
resource "aws_s3_bucket" "raw" {
  bucket        = "${var.prefix}-raw-${local.region}"
  force_destroy = true
}

resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.prefix}-athena-results-${local.region}"
  force_destroy = true
}

# --------------------------- IAM: Firehose (1 role) ---------------------------
resource "aws_iam_role" "firehose_role" {
  name = "${var.prefix}-firehose-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "firehose.amazonaws.com" }, Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "firehose_policy" {
  name = "${var.prefix}-firehose-policy"
  role = aws_iam_role.firehose_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [aws_s3_bucket.raw.arn, "${aws_s3_bucket.raw.arn}/*"]
      },
    ]
  })
}

# --------------------------- FIREHOSE (1) ---------------------------
# DirectPut, not Kinesis-as-source: scripts/produce.py writes straight to
# Firehose. A real pipeline would often sit this behind a Kinesis stream
# for multi-consumer fan-out, but LocalEmu's Firehose-consumes-from-Kinesis
# path doesn't actually deliver records to the destination today (it
# polls via GetRecords but nothing reaches S3) - found by testing this
# exact lab. DirectPut is itself a legitimate, common real-AWS pattern
# (e.g. a Lambda-based ingestion layer writing straight to Firehose), not
# a downgrade - see the README.
resource "aws_kinesis_firehose_delivery_stream" "events" {
  name        = "${var.prefix}-events"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose_role.arn
    bucket_arn         = aws_s3_bucket.raw.arn
    prefix             = "events/"
    error_output_prefix = "errors/"
    buffering_size      = 1
    buffering_interval   = 10
    file_extension      = ".json"
  }
}

# --------------------------- GLUE (2) ---------------------------
resource "aws_glue_catalog_database" "analytics" {
  # Deliberately not derived from var.prefix (which contains a hyphen):
  # Athena/SQL needs a hyphenated identifier quoted on every query
  # ("le-analytics_db".events), which is a needless distraction mid-demo.
  name = "retail_analytics_db"
}

resource "aws_glue_catalog_table" "events" {
  name          = "events"
  database_name = aws_glue_catalog_database.analytics.name

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.raw.bucket}/events/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    columns {
      name = "order_id"
      type = "string"
    }
    columns {
      name = "event"
      type = "string"
    }
    columns {
      name = "amount"
      type = "double"
    }
    columns {
      name = "customer"
      type = "string"
    }
  }
}
