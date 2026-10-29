###############################################################################
# event-application module — outputs
###############################################################################

output "producer_function_name" {
  value       = module.producer.lambda_function_name
  description = "Producer Lambda function name."
}

output "producer_function_arn" {
  value       = module.producer.lambda_function_arn
  description = "Producer Lambda function ARN."
}

output "consumer_function_name" {
  value       = module.consumer.lambda_function_name
  description = "Consumer Lambda function name."
}

output "consumer_log_group" {
  value       = module.consumer.lambda_cloudwatch_log_group_name
  description = "Consumer Lambda CloudWatch log group."
}

output "dlq_url" {
  value       = module.dlq.queue_url
  description = "Dead-letter queue URL."
}

output "dlq_arn" {
  value       = module.dlq.queue_arn
  description = "Dead-letter queue ARN."
}

output "dlq_name" {
  value       = module.dlq.queue_name
  description = "Dead-letter queue name."
}

output "sns_topic_arn" {
  value       = aws_sns_topic.notifications.arn
  description = "Application SNS topic ARN."
}

output "consumer_failure_queue_url" {
  value       = var.enable_consumer_on_failure ? module.consumer_failures[0].queue_url : ""
  description = "URL of the consumer processing-failure queue (Lambda on-failure destination). Empty when disabled."
}

output "consumer_failure_queue_arn" {
  value       = var.enable_consumer_on_failure ? module.consumer_failures[0].queue_arn : ""
  description = "ARN of the consumer processing-failure queue. Empty when disabled."
}

output "consumer_failure_queue_name" {
  value       = var.enable_consumer_on_failure ? module.consumer_failures[0].queue_name : ""
  description = "Name of the consumer processing-failure queue. Empty when disabled."
}
