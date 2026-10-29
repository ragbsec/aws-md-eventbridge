###############################################################################
# platform-global/ root — outputs
###############################################################################

output "global_endpoint_url" {
  description = "EventBridge global endpoint URL."
  value       = aws_cloudwatch_event_endpoint.global.endpoint_url
}

output "global_endpoint_id" {
  description = "EventBridge global endpoint EndpointId to pass to producers as ENDPOINT_ID (the '<id>.<suffix>' subdomain of the endpoint URL)."
  value       = replace(replace(aws_cloudwatch_event_endpoint.global.endpoint_url, "https://", ""), ".endpoint.events.amazonaws.com", "")
}

output "health_endpoint_url" {
  description = "Public health endpoint URL (Lambda Function URL) the Route 53 health check probes."
  value       = module.health_endpoint.lambda_function_url
}

output "health_function_name" {
  description = "Name of the health Lambda. Flip its HEALTHY env var to false to simulate a primary outage and trigger failover."
  value       = module.health_endpoint.lambda_function_name
}

output "health_check_id" {
  description = "Route 53 health check id."
  value       = aws_route53_health_check.primary.id
}

output "replication_role_arn" {
  description = "ARN of the IAM role EventBridge assumes to replicate events between the regional buses."
  value       = aws_iam_role.replication.arn
}
