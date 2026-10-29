###############################################################################
# application/ root — outputs
###############################################################################

output "primary" {
  description = "Primary-region application coordinates."
  value = {
    region        = var.primary_region
    producer      = module.app_primary.producer_function_name
    consumer      = module.app_primary.consumer_function_name
    consumer_logs = module.app_primary.consumer_log_group
    dlq_url       = module.app_primary.dlq_url
    sns_topic     = module.app_primary.sns_topic_arn
  }
}

output "secondary" {
  description = "Secondary-region application coordinates."
  value = {
    region        = var.secondary_region
    producer      = module.app_secondary.producer_function_name
    consumer      = module.app_secondary.consumer_function_name
    consumer_logs = module.app_secondary.consumer_log_group
    dlq_url       = module.app_secondary.dlq_url
    sns_topic     = module.app_secondary.sns_topic_arn
  }
}
