output "agent_function_name" {
  value = aws_lambda_function.agent.function_name
}

output "check_order_status_function_name" {
  value = aws_lambda_function.check_order_status.function_name
}

output "create_ticket_function_name" {
  value = aws_lambda_function.create_ticket.function_name
}

output "opensearch_endpoint" {
  value = aws_opensearch_domain.kb.endpoint
}

output "orders_table" {
  value = aws_dynamodb_table.orders.name
}

output "tickets_table" {
  value = aws_dynamodb_table.tickets.name
}
