variable "region" {
  description = "AWS region (must match the region of the existing event bus)."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional AWS CLI profile name for the deployer. Empty = default credential chain."
  type        = string
  default     = ""
}

variable "bus_name" {
  description = "Name of the existing EventBridge custom bus."
  type        = string
  default     = "eb-prod-orders"
}

variable "event_source" {
  description = "Event source used by the lab (matched by the rule, stamped by the bridge)."
  type        = string
  default     = "prod.orders"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "eb-mq"
}

variable "mq_image" {
  description = "IBM MQ developer container image."
  type        = string
  default     = "icr.io/ibm-messaging/mq:10.0.0.5-r2"
}

variable "compose_version" {
  description = "Docker Compose plugin version fetched at boot (pinned)."
  type        = string
  default     = "v2.29.7"
}

variable "instance_type" {
  description = "EC2 instance type for the MQ host. Account policy allows ONLY the t2, t3, t3a and t4g families in micro, small and medium. This stack is x86_64-only, so t4g (Graviton/ARM) is rejected below. micro (1 GiB) is too small for MQ + the bridge in practice: use small or medium."
  type        = string
  default     = "t3.medium"

  validation {
    condition     = can(regex("^(t2|t3|t3a|t4g)\\.(micro|small|medium)$", var.instance_type))
    error_message = "instance_type must be one of the allowed types: t2, t3, t3a or t4g in micro, small or medium (e.g. t3.medium)."
  }

  validation {
    condition     = !startswith(var.instance_type, "t4g.")
    error_message = "t4g is allowed by account policy but is ARM (Graviton). This stack's AMI parameter, Docker Compose binary and IBM MQ client are x86_64, so choose t2, t3 or t3a."
  }
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GiB. Account policy caps volumes at 100 GiB; AL2023 + Docker + the MQ image need at least ~20."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_gb >= 20 && var.root_volume_gb <= 100
    error_message = "root_volume_gb must be between 20 and 100 (account policy: max volume size 100 GB)."
  }
}

variable "vpc_id" {
  description = "VPC ID. Empty = default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID. Empty = first subnet (sorted by ID) of the VPC."
  type        = string
  default     = ""
}

variable "associate_public_ip" {
  description = "Give the instance a public IP (needed for outbound internet in a default-VPC public subnet without NAT)."
  type        = bool
  default     = true
}

variable "mq_client_cidrs" {
  description = "CIDRs allowed to reach the MQ listener (1414). Empty = no rule."
  type        = list(string)
  default     = []
}

variable "console_cidrs" {
  description = "CIDRs allowed to reach the MQ web console (9443). Empty = no rule."
  type        = list(string)
  default     = []
}

variable "secret_name" {
  description = "Secrets Manager secret name holding admin_password and app_password (container only; values written by the instance)."
  type        = string
  default     = "eb-mq/credentials"
}

variable "eb_endpoint_id" {
  description = "Optional EventBridge global endpoint ID for the bridge (needs awscrt for SigV4a). Empty = disabled."
  type        = string
  default     = ""
}

variable "failover_bus_arns" {
  description = "ARNs of the buses in OTHER regions that a global-endpoint failover may redirect PutEvents to (e.g. the us-west-2 eb-prod-orders bus). Same pattern as modules/event-application. Empty when eb_endpoint_id is unused."
  type        = list(string)
  default     = []
}

variable "failover_kms_key_arns" {
  description = "ARNs of the CMKs of those failover buses, so events redirected there can be encrypted. Empty when eb_endpoint_id is unused."
  type        = list(string)
  default     = []
}

variable "sqs_retention_seconds" {
  description = "Message retention for the outbound queue."
  type        = number
  default     = 345600
}

variable "tags" {
  description = "Extra tags merged onto all resources."
  type        = map(string)
  default     = {}
}
