###############################################################################
# platform-primary/ root — outputs
#
# Consumed via terraform_remote_state by:
#   platform-secondary (kms_key_arn -> KMS replica primary_key_arn)
#   platform-global    (bus_arn, kms_key_arn -> endpoint + replication role/grant)
#   application        (the whole `platform` object)
###############################################################################

output "region" {
  description = "Primary region."
  value       = var.region
}

output "kms_key_arn" {
  description = "Primary-region multi-region CMK ARN. platform-secondary uses this as the replica's primary_key_arn."
  value       = module.kms_primary.key_arn
}

output "bus_name" {
  description = "Primary bus name."
  value       = module.platform.bus_name
}

output "bus_arn" {
  description = "Primary bus ARN."
  value       = module.platform.bus_arn
}

# A single bundled object the application root reads as `platform.primary`.
output "platform" {
  description = "Primary-region platform coordinates."
  value = {
    region        = var.region
    bus_name      = module.platform.bus_name
    bus_arn       = module.platform.bus_arn
    rule_name     = module.platform.rule_name
    rule_arn      = module.platform.rule_arn
    audit_log     = module.platform.audit_log_group_name
    audit_log_arn = module.platform.audit_log_group_arn
    alerts_topic  = module.platform.alerts_topic_arn
    dashboard     = module.platform.dashboard_name
    kms_key_arn   = module.kms_primary.key_arn
  }
}

output "access_analyzer_external_arn" {
  description = "ARN of the external-access IAM Access Analyzer. Empty when disabled."
  value       = var.enable_access_analyzer_external ? aws_accessanalyzer_analyzer.external[0].arn : ""
}

output "access_analyzer_unused_arn" {
  description = "ARN of the unused-access IAM Access Analyzer. Empty when disabled."
  value       = var.enable_access_analyzer_unused ? aws_accessanalyzer_analyzer.unused[0].arn : ""
}
