###############################################################################
# eventbridge-platform module — variables
#
# A reusable, region-agnostic EventBridge PLATFORM: a KMS-encrypted custom bus,
# a routing rule, an archive, CloudWatch logging, and monitoring (alarms +
# dashboard + alerting topic). Applied once per region. The APPLICATION objects
# (Lambdas, queues, app SNS) live in a separate root and reference this bus.
###############################################################################

variable "name_prefix" {
  description = "Prefix for all platform resource names."
  type        = string
}

variable "bus_name" {
  description = "Custom bus name. MUST be identical in every region for EventBridge global-endpoint failover to work."
  type        = string
}

variable "event_source" {
  description = "The `source` field the routing rule matches."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the bus, archive and log group."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention (days) for the platform audit/log groups."
  type        = number
  default     = 30
}

variable "archive_retention_days" {
  description = "EventBridge archive retention in days (0 = indefinite)."
  type        = number
  default     = 7
}

variable "alarm_actions_enabled" {
  description = "Whether CloudWatch alarms publish to the alerting SNS topic."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Optional email address to subscribe to the alerting SNS topic. AWS sends a confirmation email (subscription is pending until confirmed). Empty = no subscription created."
  type        = string
  default     = ""
}

###############################################################################
# Cross-account / org-wide bus sharing (optional; empty = single-account only)
###############################################################################

variable "trusted_account_ids" {
  description = "AWS account IDs allowed to PutEvents to this bus (cross-account sharing). Empty = no cross-account access. Each foreign account's publishers also need KMS access to the bus CMK (see the root's cross-account KMS grant)."
  type        = list(string)
  default     = []
}

variable "organization_id" {
  description = "AWS Organizations org id (o-xxxx). When set, any principal in the org may PutEvents to this bus (aws:PrincipalOrgID condition). Empty = no org-wide access."
  type        = string
  default     = ""
}

variable "forward_to_bus_arns" {
  description = "Event bus ARNs in OTHER accounts/regions to FORWARD matched events to (cross-account consuming). Creates a forwarding rule + EventBridge PutEvents role. The remote bus must allow this account in its own resource policy. Empty = no forwarding."
  type        = list(string)
  default     = []
}

###############################################################################
# Enterprise capabilities (all opt-in; empty/false = not created)
###############################################################################

# --- Schema Registry ---
variable "enable_schema_registry" {
  description = "Create an EventBridge Schema Registry and register the OrderPlaced contract schema."
  type        = bool
  default     = false
}

variable "enable_schema_discoverer" {
  description = "Also create a discoverer that auto-infers schemas from events on the bus (requires enable_schema_registry)."
  type        = bool
  default     = false
}

variable "order_placed_schema_json" {
  description = "DEPRECATED — use var.schemas. Kept for compatibility; ignored."
  type        = string
  default     = ""
}

variable "schemas" {
  description = "Map of event-contract schemas to register: key = schema name (e.g. 'prod.orders@OrderPlaced'), value = OpenAPI/JSON Schema content. Each app team adds an entry to onboard their event; no module change needed."
  type        = map(string)
  default     = {}
}

# --- Scheduler ---
variable "enable_scheduler" {
  description = "Create an EventBridge Scheduler schedule that invokes schedule_target_arn on schedule_expression."
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "Schedule expression for the Scheduler (e.g. 'rate(1 hour)' or 'cron(0 12 * * ? *)')."
  type        = string
  default     = "rate(1 hour)"
}

variable "schedule_target_arn" {
  description = "ARN the Scheduler invokes (e.g. the producer Lambda). Required when enable_scheduler = true."
  type        = string
  default     = ""
}

# --- Pipes ---
variable "enable_pipe" {
  description = "Create an EventBridge Pipe from pipe_source_arn to this bus."
  type        = bool
  default     = false
}

variable "pipe_source_arn" {
  description = "Source ARN for the Pipe (e.g. an SQS queue). Required when enable_pipe = true."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
