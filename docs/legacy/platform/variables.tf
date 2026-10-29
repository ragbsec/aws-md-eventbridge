###############################################################################
# platform/ root — variables (multi-region EventBridge platform)
###############################################################################

variable "primary_region" {
  description = "Primary AWS region. Prod: us-east-1. Sandbox test also uses us-east-1."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-east-2", "us-west-2"], var.primary_region)
    error_message = "primary_region must be us-east-1, us-east-2, or us-west-2 (sandbox allows us-east-1/us-west-2)."
  }
}

variable "secondary_region" {
  description = "Secondary (failover) region. Prod: us-east-2. Sandbox test: us-west-2 (us-east-2 is NOT available in the Pluralsight sandbox)."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = contains(["us-east-1", "us-east-2", "us-west-2"], var.secondary_region)
    error_message = "secondary_region must be us-east-1, us-east-2, or us-west-2 (sandbox allows us-east-1/us-west-2)."
  }
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
  description = "Custom bus name — identical in both regions (required for global-endpoint failover)."
  type        = string
  default     = "eb-prod-orders"
}

variable "event_source" {
  description = "The event source the routing rule matches."
  type        = string
  default     = "prod.orders"
}

variable "enable_global_endpoint" {
  description = <<-EOT
    Create the EventBridge global endpoint + Route 53 health check for automatic
    regional failover. Requires BOTH regions deployed with the same bus name.
    Route 53 health checks are a global (billed) resource; leave off for a
    single-region sandbox test, turn on for production multi-region.
  EOT
  type        = bool
  default     = false
}

variable "health_check_domain" {
  description = "Public HTTPS domain the Route 53 health check probes to decide primary-region health (only used when enable_global_endpoint = true). Typically a health endpoint of your primary-region app."
  type        = string
  default     = ""
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
  description = "Optional email subscribed to the per-region alerting SNS topics. AWS sends a confirmation email; the subscription is pending until confirmed. Empty = no subscription."
  type        = string
  default     = ""
}

###############################################################################
# Cross-account / org-wide bus sharing (optional; empty = single-account only)
###############################################################################

variable "trusted_account_ids" {
  description = "AWS account IDs allowed to PutEvents to the bus in BOTH regions (cross-account sharing). Empty = no cross-account access. These accounts are also granted KMS use on the bus CMKs so their encrypted PutEvents succeed."
  type        = list(string)
  default     = []
}

variable "organization_id" {
  description = "AWS Organizations org id (o-xxxx) for org-wide bus access (aws:PrincipalOrgID). Empty = no org-wide access. When set, the CMKs also allow org-wide KMS use for PutEvents."
  type        = string
  default     = ""
}

variable "forward_to_bus_arns" {
  description = "Event bus ARNs in other accounts/regions to forward matched events to (cross-account consuming), applied in BOTH regions. The remote bus must trust this account in its own resource policy. Empty = no forwarding."
  type        = list(string)
  default     = []
}

###############################################################################
# Enterprise capabilities (opt-in; applied in both regions)
###############################################################################

variable "enable_schema_registry" {
  description = "Create a Schema Registry + register the OrderPlaced contract in both regions."
  type        = bool
  default     = false
}

variable "enable_schema_discoverer" {
  description = "Also auto-discover schemas from bus events (requires enable_schema_registry)."
  type        = bool
  default     = false
}

variable "schemas_dir" {
  description = "Directory of per-team event-contract schema files (*.json). Every file is registered; onboarding a new app team = drop a new file here. Each file name (sans .json) becomes the schema name, with '/' allowed via '__' -> handled by the loader local."
  type        = string
  default     = "../schemas"
}

variable "enable_scheduler" {
  description = "Create an EventBridge Scheduler schedule invoking schedule_target_arn."
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "Scheduler expression, e.g. 'rate(1 hour)' or 'cron(0 12 * * ? *)'."
  type        = string
  default     = "rate(1 hour)"
}

variable "schedule_target_arn" {
  description = "ARN the Scheduler invokes (e.g. producer Lambda). Required when enable_scheduler=true."
  type        = string
  default     = ""
}

variable "enable_pipe" {
  description = "Create an EventBridge Pipe from pipe_source_arn to the bus."
  type        = bool
  default     = false
}

variable "pipe_source_arn" {
  description = "Source ARN for the Pipe (e.g. SQS queue). Required when enable_pipe=true."
  type        = string
  default     = ""
}

###############################################################################
# Detective control: IAM Access Analyzer (owned by the platform owner)
###############################################################################

variable "enable_access_analyzer_external" {
  description = "Create an IAM Access Analyzer for EXTERNAL access — flags any resource policy (bus, SQS, SNS, KMS, roles) granting access outside the account/org. Platform-owner toggle."
  type        = bool
  default     = false
}

variable "enable_access_analyzer_unused" {
  description = "Create an IAM Access Analyzer for UNUSED access — flags IAM roles/permissions that go unused (e.g. over-granted producer/consumer roles). Platform-owner toggle."
  type        = bool
  default     = false
}

variable "access_analyzer_org_scope" {
  description = "If true, analyzers are ORGANIZATION-scoped (requires the account be the Organizations management or a delegated-admin account). If false, ACCOUNT-scoped."
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
    Layer     = "platform"
  }
}
