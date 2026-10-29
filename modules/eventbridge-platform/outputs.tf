###############################################################################
# eventbridge-platform module — outputs
###############################################################################

output "bus_name" {
  description = "Custom EventBridge bus name."
  value       = module.eventbridge.eventbridge_bus_name
}

output "bus_arn" {
  description = "Custom EventBridge bus ARN."
  value       = module.eventbridge.eventbridge_bus_arn
}

output "rule_name" {
  description = "Routing rule name (bare, for the application layer to attach targets)."
  # The module's rule id is "<bus>/<rule>" on a custom bus; targets need the
  # bare rule name, so strip the "<bus>/" prefix.
  value = element(split("/", module.eventbridge.eventbridge_rule_ids["order_placed"]), length(split("/", module.eventbridge.eventbridge_rule_ids["order_placed"])) - 1)
}

output "rule_arn" {
  description = "Routing rule ARN."
  value       = module.eventbridge.eventbridge_rule_arns["order_placed"]
}

output "audit_log_group_name" {
  description = "CloudWatch audit log group name."
  value       = aws_cloudwatch_log_group.audit.name
}

output "audit_log_group_arn" {
  description = "CloudWatch audit log group ARN."
  value       = aws_cloudwatch_log_group.audit.arn
}

output "alerts_topic_arn" {
  description = "SNS topic ARN for operational alarms."
  value       = aws_sns_topic.alerts.arn
}

output "archive_arns" {
  description = "EventBridge archive ARNs."
  value       = module.eventbridge.eventbridge_archive_arns
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.platform.dashboard_name
}
