output "function_name" {
  value = aws_lambda_function.processor.function_name
}

output "incoming_bucket" {
  value = aws_s3_bucket.incoming.id
}

output "processed_bucket" {
  value = aws_s3_bucket.processed.id
}

output "topic_arn" {
  value = aws_sns_topic.notifications.arn
}
