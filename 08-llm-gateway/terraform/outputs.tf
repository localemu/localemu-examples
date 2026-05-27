output "api_endpoint" {
  value = aws_apigatewayv2_api.api.api_endpoint
}

output "api_id" {
  value = aws_apigatewayv2_api.api.id
}

output "cache_table" {
  value = aws_dynamodb_table.cache.name
}

output "incidents_table" {
  value = aws_dynamodb_table.incidents.name
}

output "scores_table" {
  value = aws_dynamodb_table.scores.name
}

output "eval_queue_url" {
  value = aws_sqs_queue.eval.url
}

output "eval_dlq_url" {
  value = aws_sqs_queue.eval_dlq.url
}

output "event_bus_name" {
  value = aws_cloudwatch_event_bus.bus.name
}
