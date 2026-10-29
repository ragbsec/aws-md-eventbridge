###############################################################################
# App layer — outputs (used by the test harness to verify every object)
###############################################################################

output "event_bus_name" {
  description = "Custom EventBridge bus name."
  value       = module.eventbridge.eventbridge_bus_name
}

output "event_bus_arn" {
  description = "Custom EventBridge bus ARN."
  value       = module.eventbridge.eventbridge_bus_arn
}

output "rule_arns" {
  description = "EventBridge rule ARNs."
  value       = module.eventbridge.eventbridge_rule_arns
}

output "producer_function_name" {
  description = "Producer Lambda function name."
  value       = module.producer.lambda_function_name
}

output "consumer_function_name" {
  description = "Consumer Lambda function name."
  value       = module.consumer.lambda_function_name
}

output "consumer_log_group" {
  description = "CloudWatch Logs group for the consumer Lambda."
  value       = module.consumer.lambda_cloudwatch_log_group_name
}

output "audit_log_group" {
  description = "CloudWatch Logs group receiving every matched event."
  value       = aws_cloudwatch_log_group.audit.name
}

output "dlq_url" {
  description = "Dead-letter queue URL."
  value       = module.dlq.queue_url
}

output "dlq_arn" {
  description = "Dead-letter queue ARN."
  value       = module.dlq.queue_arn
}

output "sns_topic_arn" {
  description = "SNS notification topic ARN."
  value       = module.sns.topic_arn
}

output "schedule_group" {
  description = "EventBridge Scheduler group name(s)."
  value       = module.eventbridge.eventbridge_schedule_group_ids
}

output "schedule_arns" {
  description = "EventBridge Scheduler schedule ARNs."
  value       = module.eventbridge.eventbridge_schedule_arns
}

output "archive_arns" {
  description = "EventBridge archive ARNs (replayable event store)."
  value       = module.eventbridge.eventbridge_archive_arns
}
