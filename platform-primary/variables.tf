###############################################################################
# platform-primary/ root — variables
###############################################################################

variable "region" {
  description = "PRIMARY AWS region for this root's state and resources."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-east-2", "us-west-2"], var.region)
    error_message = "region must be us-east-1, us-east-2, or us-west-2."
  }
}

variable "secondary_region" {
  description = "The SECONDARY region name — used only to scope the cross-account KMS kms:ViaService condition to both platform regions. The secondary resources themselves live in platform-secondary/."
  type        = string
  default     = "us-west-2"
}

variable "deployer_profile" {
  description = "AWS profile for the dedicated deployer IAM user."
  type        = string
  default     = "eventbridge-lab-deployer"
}

variable "name_prefix" {
  description = "Prefix for platform resource names."
  type        = string
  default     = "eb-prod"
}

variable "bus_name" {
  description = "Custom bus name — MUST be identical in both regions (required for global-endpoint failover)."
  type        = string
  default     = "eb-prod-orders"
}

variable "event_source" {
  description = "The event source the routing rule matches."
  type        = string
  default     = "prod.orders"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention (days)."
  type        = number
  default     = 30
}

variable "archive_retention_days" {
  description = "EventBridge archive retention (days)."
  type        = number
  default     = 7
}

variable "alert_email" {
  description = "Optional email subscribed to the primary-region alerting SNS topic. Empty = no subscription."
  type        = string
  default     = ""
}

###############################################################################
# Cross-account / org-wide bus sharing (optional; empty = single-account only)
###############################################################################

variable "trusted_account_ids" {
  description = "AWS account IDs allowed to PutEvents to the primary bus (cross-account sharing). Also granted KMS use on the primary CMK. Keep identical to the secondary root's value for symmetric failover."
  type        = list(string)
  default     = []
}

variable "organization_id" {
  description = "AWS Organizations org id (o-xxxx) for org-wide bus access. Empty = none. Keep identical to the secondary root's value."
  type        = string
  default     = ""
}

variable "forward_to_bus_arns" {
  description = "Event bus ARNs in other accounts/regions to forward matched events to (cross-account consuming). Empty = no forwarding."
  type        = list(string)
  default     = []
}

###############################################################################
# Enterprise capabilities (opt-in)
###############################################################################

variable "enable_schema_registry" {
  description = "Create a Schema Registry + register every schemas/*.json contract in the primary region."
  type        = bool
  default     = false
}

variable "enable_schema_discoverer" {
  description = "Also auto-discover schemas from bus events (requires enable_schema_registry)."
  type        = bool
  default     = false
}

variable "schemas_dir" {
  description = "Directory (relative to this root) of per-team event-contract schema files (*.json). Shared across regions, so it points at the repo-level schemas/ directory."
  type        = string
  default     = "../schemas"
}

variable "enable_scheduler" {
  description = "Create an EventBridge Scheduler schedule invoking schedule_target_arn in the primary region."
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "Scheduler expression, e.g. 'rate(1 hour)' or 'cron(0 12 * * ? *)'."
  type        = string
  default     = "rate(1 hour)"
}

variable "schedule_target_arn" {
  description = "ARN the Scheduler invokes. Required when enable_scheduler=true."
  type        = string
  default     = ""
}

variable "enable_pipe" {
  description = "Create an EventBridge Pipe from pipe_source_arn to the primary bus."
  type        = bool
  default     = false
}

variable "pipe_source_arn" {
  description = "Source ARN for the Pipe. Required when enable_pipe=true."
  type        = string
  default     = ""
}

###############################################################################
# Detective control: IAM Access Analyzer (owned by the platform owner)
###############################################################################

variable "enable_access_analyzer_external" {
  description = "Create an IAM Access Analyzer for EXTERNAL access (account/org-scoped). Platform-owner toggle."
  type        = bool
  default     = false
}

variable "enable_access_analyzer_unused" {
  description = "Create an IAM Access Analyzer for UNUSED access. Platform-owner toggle."
  type        = bool
  default     = false
}

variable "access_analyzer_org_scope" {
  description = "If true, analyzers are ORGANIZATION-scoped (requires an Organizations management/delegated-admin account). If false, ACCOUNT-scoped."
  type        = bool
  default     = false
}

variable "access_analyzer_unused_age_days" {
  description = "Days of inactivity before the unused-access analyzer flags a role/permission."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default = {
    Project   = "eventbridge-lab"
    ManagedBy = "terraform"
    Layer     = "platform-primary"
  }
}
