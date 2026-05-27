output "api_endpoint" {
  value = aws_apigatewayv2_api.api.api_endpoint
}

output "api_id" {
  value = aws_apigatewayv2_api.api.id
}

output "accounts_table" {
  value = aws_dynamodb_table.accounts.name
}

output "ledger_table" {
  value = aws_dynamodb_table.ledger.name
}

output "idempotency_table" {
  value = aws_dynamodb_table.idempotency.name
}

output "bus_name" {
  value = aws_cloudwatch_event_bus.bus.name
}

output "settled_queue_url" {
  value = aws_sqs_queue.settled.url
}
