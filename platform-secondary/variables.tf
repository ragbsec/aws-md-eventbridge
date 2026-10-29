###############################################################################
# platform-secondary/ root — variables
###############################################################################

variable "region" {
  description = "SECONDARY (failover) AWS region for this root's state and resources."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = contains(["us-east-1", "us-east-2", "us-west-2"], var.region)
    error_message = "region must be us-east-1, us-east-2, or us-west-2."
  }
}

variable "deployer_profile" {
  description = "AWS profile for the dedicated deployer IAM user."
  type        = string
  default     = "eventbridge-lab-deployer"
}

###############################################################################
# Remote-state reference to platform-primary (for the KMS replica's source key)
###############################################################################

variable "state_bucket" {
  description = "S3 bucket holding the platform-primary state (to read the primary CMK ARN)."
  type        = string
}

variable "state_region" {
  description = "Region of the state bucket (where platform-primary's state key lives)."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for platform resource names."
  type        = string
  default     = "eb-prod"
}

variable "bus_name" {
  description = "Custom bus name — MUST equal the primary root's bus_name (required for global-endpoint failover)."
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
  description = "Optional email subscribed to the secondary-region alerting SNS topic. Empty = no subscription."
  type        = string
  default     = ""
}

###############################################################################
# Cross-account / org-wide bus sharing (keep identical to the primary root)
###############################################################################

variable "trusted_account_ids" {
  description = "AWS account IDs allowed to PutEvents to the secondary bus. Also granted KMS use on the replica CMK. Keep identical to the primary root for symmetric failover."
  type        = list(string)
  default     = []
}

variable "organization_id" {
  description = "AWS Organizations org id (o-xxxx) for org-wide bus access. Keep identical to the primary root."
  type        = string
  default     = ""
}

variable "forward_to_bus_arns" {
  description = "Event bus ARNs in other accounts/regions to forward matched events to. Empty = no forwarding."
  type        = list(string)
  default     = []
}

###############################################################################
# Enterprise capabilities (opt-in)
###############################################################################

variable "enable_schema_registry" {
  description = "Create a Schema Registry + register every schemas/*.json contract in the secondary region."
  type        = bool
  default     = false
}

variable "enable_schema_discoverer" {
  description = "Also auto-discover schemas from bus events (requires enable_schema_registry)."
  type        = bool
  default     = false
}

variable "schemas_dir" {
  description = "Directory (relative to this root) of per-team event-contract schema files (*.json). Points at the shared repo-level schemas/ directory."
  type        = string
  default     = "../schemas"
}

variable "enable_scheduler" {
  description = "Create an EventBridge Scheduler schedule invoking schedule_target_arn in the secondary region."
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
  description = "Create an EventBridge Pipe from pipe_source_arn to the secondary bus."
  type        = bool
  default     = false
}

variable "pipe_source_arn" {
  description = "Source ARN for the Pipe. Required when enable_pipe=true."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default = {
    Project   = "eventbridge-lab"
    ManagedBy = "terraform"
    Layer     = "platform-secondary"
  }
}
