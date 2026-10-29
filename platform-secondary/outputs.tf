###############################################################################
# platform-secondary/ root — outputs
#
# Consumed via terraform_remote_state by:
#   platform-global (bus_arn, kms_key_arn -> endpoint + replication role/grant)
#   application     (the whole `platform` object as `secondary`)
###############################################################################

output "region" {
  description = "Secondary region."
  value       = var.region
}

output "kms_key_arn" {
  description = "Secondary-region replica CMK ARN."
  value       = module.kms_secondary.key_arn
}

output "bus_name" {
  description = "Secondary bus name."
  value       = module.platform.bus_name
}

output "bus_arn" {
  description = "Secondary bus ARN."
  value       = module.platform.bus_arn
}

output "platform" {
  description = "Secondary-region platform coordinates."
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
    kms_key_arn   = module.kms_secondary.key_arn
  }
}
