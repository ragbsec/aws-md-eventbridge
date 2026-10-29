###############################################################################
# App layer — input variables
###############################################################################

variable "region" {
  description = "AWS region. Must match the bootstrap region. Sandbox allows only us-east-1 and us-west-2."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "The Pluralsight AWS sandbox permits only us-east-1 or us-west-2."
  }
}

variable "deployer_profile" {
  description = "Named AWS profile for the dedicated deployer IAM user (NOT cloud_user). The create script writes this profile from the bootstrap output."
  type        = string
  default     = "eventbridge-lab-deployer"
}

variable "name_prefix" {
  description = "Prefix for all app resource names."
  type        = string
  default     = "eb-lab"
}

variable "bus_name" {
  description = "Name of the custom EventBridge bus."
  type        = string
  default     = "eb-lab-orders"
}

variable "event_source" {
  description = "The `source` field stamped on published events and matched by the rule."
  type        = string
  default     = "lab.orders"
}

variable "enable_schedule" {
  description = <<-EOT
    Whether to create the RECURRING EventBridge Scheduler that invokes the
    producer on a timer. Default false to keep a lab account idle-free: nothing
    runs unattended, so there is no continuous Lambda/CloudWatch cost. Set true
    to demonstrate scheduled production, or just invoke the producer on demand
    (scripts/test.sh does exactly that).
  EOT
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "EventBridge Scheduler expression for the recurring producer (rate or cron). Only used when enable_schedule = true."
  type        = string
  default     = "rate(1 hour)"
}

variable "lambda_memory_mb" {
  description = "Memory for the producer/consumer Lambdas. 128 MB keeps invocations firmly in the free tier. Sandbox cap is 2048 MB."
  type        = number
  default     = 128

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 2048
    error_message = "lambda_memory_mb must be between 128 and 2048 (sandbox cap)."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the consumer target log group and Lambda logs."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Common tags for all app resources."
  type        = map(string)
  default = {
    Project   = "eventbridge-lab"
    ManagedBy = "terraform"
    Layer     = "app"
  }
}
