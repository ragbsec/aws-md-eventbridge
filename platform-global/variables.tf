###############################################################################
# platform-global/ root — variables
###############################################################################

variable "primary_region" {
  description = "Primary region (must match platform-primary's region)."
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Secondary region (must match platform-secondary's region)."
  type        = string
  default     = "us-west-2"
}

variable "deployer_profile" {
  description = "AWS profile for the dedicated deployer IAM user."
  type        = string
  default     = "eventbridge-lab-deployer"
}

###############################################################################
# Remote-state references to the two regional roots
###############################################################################

variable "state_bucket" {
  description = "S3 bucket holding platform-primary and platform-secondary state."
  type        = string
}

variable "state_region" {
  description = "Region of the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for the global resources (endpoint, health check, replication role). MUST match the regional roots' name_prefix so the replication-role ARN self-reference resolves."
  type        = string
  default     = "eb-prod"
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default = {
    Project   = "eventbridge-lab"
    ManagedBy = "terraform"
    Layer     = "platform-global"
  }
}
