output "function_name" {
  value = aws_lambda_function.remediator.function_name
}

output "rule_name" {
  value = aws_cloudwatch_event_rule.s3_policy_changes.name
}

output "incidents_table" {
  value = aws_dynamodb_table.incidents.name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "trail_name" {
  value = aws_cloudtrail.trail.name
}
