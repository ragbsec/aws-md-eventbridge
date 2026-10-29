###############################################################################
# Bootstrap layer — input variables
###############################################################################

variable "region" {
  description = "AWS region for the state backend and the lab."
  type        = string
  default     = "us-east-1"
}

variable "operator_profile" {
  description = "Named AWS CLI/SDK profile used to RUN the bootstrap (the privileged operator). Defaults to the account's default profile."
  type        = string
  default     = "default"
}

variable "project_name" {
  description = "Short project slug used to name all bootstrap resources."
  type        = string
  default     = "eventbridge-lab"
}

variable "state_bucket_name" {
  description = <<-EOT
    Name of the S3 bucket to use for Terraform remote state.
    - Leave empty ("") to have Terraform CREATE a new, globally-unique bucket
      (name = "<project_name>-tfstate-<account_id>-<region>").
    - Set an EXISTING bucket name to REUSE a state bucket you already own; the
      bucket is then treated as data (not created or destroyed by this layer).
  EOT
  type        = string
  default     = ""
}

variable "deployer_user_name" {
  description = "Name of the dedicated, least-privilege IAM user that will APPLY and DESTROY the app layer (never cloud_user)."
  type        = string
  default     = "eventbridge-lab-deployer"
}

variable "tags" {
  description = "Common tags applied to every bootstrap resource."
  type        = map(string)
  default = {
    Project   = "eventbridge-lab"
    ManagedBy = "terraform"
    Layer     = "bootstrap"
  }
}

###############################################################################
# GitLab CI/CD OIDC federation (production deploy identity — gap #3)
#
# All off by default so the sandbox access-key path is unchanged. Enable for the
# real account with: -var enable_gitlab_oidc=true -var gitlab_project_path=...
###############################################################################

variable "enable_gitlab_oidc" {
  description = "Create the GitLab OIDC provider + federated deployer role instead of relying on the static IAM-user key. Leave false for the sandbox."
  type        = bool
  default     = false
}

variable "gitlab_url" {
  description = "GitLab instance URL and OIDC issuer. gitlab.com SaaS = https://gitlab.com; self-managed = your instance URL (no trailing slash)."
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_oidc_thumbprint" {
  description = <<-EOT
    SHA-1 thumbprint of the GitLab OIDC issuer's root CA. For gitlab.com this is
    the well-known root-CA thumbprint; AWS ignores it for public-CA hosts but
    the API still requires a value. Override for a self-managed instance with a
    private CA. Default is the gitlab.com root-CA thumbprint.
  EOT
  type        = string
  default     = "b3dd7606d2b5a8b4a13771dbecc9ee1ccd56b9bb"
}

variable "gitlab_project_path" {
  description = "GitLab project path 'group/project' (or 'group/subgroup/project'). Used to build the default allowed sub claim."
  type        = string
  default     = ""
}

variable "gitlab_allowed_sub" {
  description = <<-EOT
    The OIDC `sub` claim pattern (StringLike) a CI job must match to assume the
    deploy role. Least privilege: scope to the project + the refs allowed to
    deploy. Examples:
      - default branch only : project_path:group/project:ref_type:branch:ref:main
      - any protected branch: project_path:group/project:ref_type:branch:ref:*
      - a deploy tag        : project_path:group/project:ref_type:tag:ref:deploy-*
    Leave empty to auto-build 'project_path:<gitlab_project_path>:ref_type:branch:ref:main'.
  EOT
  type        = string
  default     = ""
}

variable "gitlab_role_max_session" {
  description = "Max session duration (seconds) for the assumed CI role. 3600 = 1h; raise for very long applies."
  type        = number
  default     = 3600

  validation {
    condition     = var.gitlab_role_max_session >= 900 && var.gitlab_role_max_session <= 43200
    error_message = "gitlab_role_max_session must be between 900 and 43200 seconds."
  }
}

###############################################################################
# Assumed deployer ROLE (human/CI identities) — production alternative to the
# static access key. Off by default; the trust principals are configurable.
###############################################################################

variable "enable_deployer_role" {
  description = "Create an assumable deployer role (trusted by deployer_trust_principals) instead of relying only on the static IAM-user key. Requires sts:AssumeRole to be permitted in the account."
  type        = bool
  default     = false
}

variable "deployer_trust_principals" {
  description = <<-EOT
    IAM principal ARNs allowed to ASSUME the deployer role. Add users or CI
    identities here to authorize additional deployers — least privilege: name
    each principal explicitly, avoid account :root. Examples:
      ["arn:aws:iam::123456789012:user/cloud_user"]
      ["arn:aws:iam::123456789012:user/alice", "arn:aws:iam::123456789012:user/bob"]
    Must be non-empty when enable_deployer_role = true.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_deployer_role || length(var.deployer_trust_principals) > 0
    error_message = "deployer_trust_principals must list at least one principal ARN when enable_deployer_role = true (otherwise the role is un-assumable)."
  }
}

variable "deployer_external_id" {
  description = "Optional sts:ExternalId required to assume the deployer role (recommended for cross-account use). Empty string disables the condition."
  type        = string
  default     = ""
}

variable "deployer_role_max_session" {
  description = "Max session duration (seconds) for the assumed deployer role."
  type        = number
  default     = 3600

  validation {
    condition     = var.deployer_role_max_session >= 900 && var.deployer_role_max_session <= 43200
    error_message = "deployer_role_max_session must be between 900 and 43200 seconds."
  }
}
