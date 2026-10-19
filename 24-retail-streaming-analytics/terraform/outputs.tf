output "delivery_stream_name" {
  value = aws_kinesis_firehose_delivery_stream.events.name
}

output "raw_bucket" {
  value = aws_s3_bucket.raw.bucket
}

output "athena_results_bucket" {
  value = aws_s3_bucket.athena_results.bucket
}

output "glue_database" {
  value = aws_glue_catalog_database.analytics.name
}

output "glue_table" {
  value = aws_glue_catalog_table.events.name
}
