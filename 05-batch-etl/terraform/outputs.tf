output "input_bucket" {
  value = aws_s3_bucket.input.id
}

output "table_name" {
  value = aws_dynamodb_table.orders.name
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.etl.arn
}

output "parse_function_name" {
  value = aws_lambda_function.parse.function_name
}

output "load_row_function_name" {
  value = aws_lambda_function.load_row.function_name
}
