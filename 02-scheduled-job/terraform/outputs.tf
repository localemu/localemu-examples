output "function_name" {
  value = aws_lambda_function.check.function_name
}

output "function_arn" {
  value = aws_lambda_function.check.arn
}

output "schedule_name" {
  value = aws_scheduler_schedule.hourly.name
}

output "schedule_expression" {
  value = aws_scheduler_schedule.hourly.schedule_expression
}

output "table_name" {
  value = aws_dynamodb_table.audit.name
}

output "fresh_secret_name" {
  value = aws_secretsmanager_secret.fresh.name
}

output "stale_secret_name" {
  value = aws_secretsmanager_secret.stale.name
}

output "ignored_secret_name" {
  value = aws_secretsmanager_secret.ignored.name
}
