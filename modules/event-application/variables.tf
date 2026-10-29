###############################################################################
# event-application module — variables
#
# The APPLICATION objects that produce/consume events on a platform bus:
# producer + consumer Lambdas, an SQS DLQ, an app SNS topic, and the rule
# TARGETS that wire them to the platform's routing rule. Kept separate from the
# platform so the two can be versioned and deployed independently.
###############################################################################

variable "name_prefix" {
  description = "Prefix for all application resource names."
  type        = string
}

variable "bus_name" {
  description = "Name of the platform event bus to publish to / consume from."
  type        = string
}

variable "bus_arn" {
  description = "ARN of the platform event bus (for producer PutEvents permission)."
  type        = string
}

variable "failover_bus_arns" {
  description = "ARNs of OTHER regional buses a global-endpoint failover may redirect PutEvents to. The producer is granted PutEvents on these too. Empty when not using a global endpoint."
  type        = list(string)
  default     = []
}

variable "failover_kms_key_arns" {
  description = "CMK ARNs of the failover regions' buses, so the producer can encrypt events redirected there on failover. Empty when not using a global endpoint."
  type        = list(string)
  default     = []
}

variable "rule_name" {
  description = "Name of the platform routing rule to attach targets to."
  type        = string
}

variable "rule_arn" {
  description = "ARN of the platform routing rule (for Lambda invoke permission scoping)."
  type        = string
}

variable "audit_log_group_arn" {
  description = "ARN of the platform's audit CloudWatch log group (a rule target for the event audit trail)."
  type        = string
}

variable "alerts_topic_arn" {
  description = "ARN of the platform's alerting SNS topic. The DLQ alarm publishes here when it breaches. Empty = alarm has no action."
  type        = string
  default     = ""
}

###############################################################################
# Consumer processing-failure dead-letter (platform default: ON)
#
# The EventBridge TARGET DLQ (dead_letter_config on the rule target) only
# captures events EventBridge fails to DELIVER. When the consumer Lambda IS
# invoked but its handler THROWS (a bug, bad data, a downstream outage), that is
# a Lambda ASYNC-invocation failure — governed by the Lambda's own async invoke
# config, NOT the target DLQ. Without an on-failure destination the Lambda
# retries on its defaults and then DROPS the event silently. This wires a
# dedicated failure queue + alarm so a processing failure is durable and visible.
###############################################################################

variable "enable_consumer_on_failure" {
  description = "Platform default (true): give the consumer Lambda an async on-failure destination (a dedicated SQS failure queue) so events whose HANDLER throws are dead-lettered + alarmed instead of silently dropped. Set false only for a consumer that is genuinely fire-and-forget."
  type        = bool
  default     = true
}

variable "consumer_max_retry_attempts" {
  description = "Lambda async-invocation retry attempts before the consumer's on-failure destination receives the event (0-2)."
  type        = number
  default     = 2

  validation {
    condition     = var.consumer_max_retry_attempts >= 0 && var.consumer_max_retry_attempts <= 2
    error_message = "consumer_max_retry_attempts must be between 0 and 2 (Lambda async-invoke limit)."
  }
}

variable "event_source" {
  description = "The `source` stamped on published events."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN for DLQ, SNS and Lambda env encryption."
  type        = string
}

variable "lambda_source_dir" {
  description = "Absolute path to the directory holding the Lambda source (producer/ and consumer/ subdirs)."
  type        = string
}

variable "lambda_memory_mb" {
  description = "Memory for the Lambdas (MB)."
  type        = number
  default     = 128
}

variable "lambda_timeout" {
  description = "Timeout for the Lambdas (seconds)."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda log groups."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
