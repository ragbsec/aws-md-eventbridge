###############################################################################
# application/ root — variables
###############################################################################

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "secondary_region" {
  type    = string
  default = "us-west-2"
}

variable "deployer_profile" {
  type    = string
  default = "eventbridge-lab-deployer"
}

variable "name_prefix" {
  type    = string
  default = "eb-prod"
}

variable "event_source" {
  type    = string
  default = "prod.orders"
}

variable "lambda_memory_mb" {
  type    = number
  default = 128
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "state_bucket" {
  description = "S3 bucket holding the platform layer's state (to read its outputs)."
  type        = string
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "eventbridge-lab"
    ManagedBy = "terraform"
    Layer     = "application"
  }
}
