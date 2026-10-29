###############################################################################
# platform/ root — outputs (the application root reads these)
###############################################################################

output "kms_key_arn_primary" {
  value       = module.kms_primary.key_arn
  description = "Primary-region CMK ARN."
}

output "kms_key_arn_secondary" {
  value       = module.kms_secondary.key_arn
  description = "Secondary-region CMK ARN."
}

output "bus_name" {
  value       = var.bus_name
  description = "Bus name (same in both regions)."
}

output "primary" {
  description = "Primary-region platform coordinates."
  value = {
    region        = var.primary_region
    bus_name      = module.platform_primary.bus_name
    bus_arn       = module.platform_primary.bus_arn
    rule_name     = module.platform_primary.rule_name
    rule_arn      = module.platform_primary.rule_arn
    audit_log     = module.platform_primary.audit_log_group_name
    audit_log_arn = module.platform_primary.audit_log_group_arn
    alerts_topic  = module.platform_primary.alerts_topic_arn
    dashboard     = module.platform_primary.dashboard_name
    kms_key_arn   = module.kms_primary.key_arn
  }
}

output "secondary" {
  description = "Secondary-region platform coordinates."
  value = {
    region        = var.secondary_region
    bus_name      = module.platform_secondary.bus_name
    bus_arn       = module.platform_secondary.bus_arn
    rule_name     = module.platform_secondary.rule_name
    rule_arn      = module.platform_secondary.rule_arn
    audit_log     = module.platform_secondary.audit_log_group_name
    audit_log_arn = module.platform_secondary.audit_log_group_arn
    alerts_topic  = module.platform_secondary.alerts_topic_arn
    dashboard     = module.platform_secondary.dashboard_name
    kms_key_arn   = module.kms_secondary.key_arn
  }
}

output "global_endpoint_url" {
  description = "EventBridge global endpoint URL. Empty when disabled."
  value       = var.enable_global_endpoint ? aws_cloudwatch_event_endpoint.global[0].endpoint_url : ""
}

output "global_endpoint_id" {
  description = "EventBridge global endpoint EndpointId to pass to producers as ENDPOINT_ID (the '<id>.<suffix>' subdomain of the endpoint URL). Empty when disabled."
  value = (
    var.enable_global_endpoint
    ? replace(replace(aws_cloudwatch_event_endpoint.global[0].endpoint_url, "https://", ""), ".endpoint.events.amazonaws.com", "")
    : ""
  )
}

output "health_endpoint_url" {
  description = "Public health endpoint URL (Lambda Function URL) the Route 53 health check probes. Empty when global endpoint disabled."
  value       = var.enable_global_endpoint ? module.health_endpoint[0].lambda_function_url : ""
}

output "health_function_name" {
  description = "Name of the health Lambda. Flip its HEALTHY env var to false to simulate a primary outage. Empty when disabled."
  value       = var.enable_global_endpoint ? module.health_endpoint[0].lambda_function_name : ""
}

output "health_check_id" {
  description = "Route 53 health check id. Empty when global endpoint disabled."
  value       = var.enable_global_endpoint ? aws_route53_health_check.primary[0].id : ""
}

output "access_analyzer_external_arn" {
  description = "ARN of the external-access IAM Access Analyzer. Empty when disabled."
  value       = var.enable_access_analyzer_external ? aws_accessanalyzer_analyzer.external[0].arn : ""
}

output "access_analyzer_unused_arn" {
  description = "ARN of the unused-access IAM Access Analyzer. Empty when disabled."
  value       = var.enable_access_analyzer_unused ? aws_accessanalyzer_analyzer.unused[0].arn : ""
}
