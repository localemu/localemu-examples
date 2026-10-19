output "function_name" {
  value = aws_lambda_function.responder.function_name
}

output "rule_name" {
  value = aws_cloudwatch_event_rule.guardduty_findings.name
}

output "incidents_table" {
  value = aws_dynamodb_table.incidents.name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "detector_id" {
  value = aws_guardduty_detector.this.id
}

output "victim_role_name" {
  value = aws_iam_role.victim.name
}

output "victim_role_arn" {
  value = aws_iam_role.victim.arn
}
