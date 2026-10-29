###############################################################################
# Bootstrap layer — outputs
###############################################################################

output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state (created or reused)."
  value       = local.state_bucket_name
}

output "state_bucket_created" {
  description = "True if this run created the state bucket; false if an existing bucket is being reused."
  value       = local.create_state_bucket
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "deployer_user_name" {
  description = "Dedicated IAM user that applies/destroys the app layer."
  value       = aws_iam_user.deployer.name
}

output "deployer_user_arn" {
  description = "ARN of the dedicated deployer IAM user."
  value       = aws_iam_user.deployer.arn
}

output "deployer_access_key_id" {
  description = "Access key ID for the deployer user."
  value       = aws_iam_access_key.deployer.id
}

output "deployer_secret_access_key" {
  description = "Secret access key for the deployer user (sensitive)."
  value       = aws_iam_access_key.deployer.secret
  sensitive   = true
}

# Convenience: the exact backend block the app layer should use.
output "app_backend_config" {
  description = "Values to pass to the app layer's S3 backend (S3-native locking)."
  value = {
    bucket       = local.state_bucket_name
    key          = "eventbridge-lab/app/terraform.tfstate"
    region       = var.region
    use_lockfile = true
    encrypt      = true
  }
}

###############################################################################
# GitLab OIDC outputs (only populated when enable_gitlab_oidc = true)
###############################################################################

output "gitlab_oidc_provider_arn" {
  description = "ARN of the GitLab OIDC identity provider (empty when disabled)."
  value       = local.gitlab_oidc_enabled ? aws_iam_openid_connect_provider.gitlab[0].arn : ""
}

output "gitlab_deployer_role_arn" {
  description = "ARN of the federated role GitLab CI assumes via OIDC. Set this as the TF_DEPLOYER_ROLE_ARN CI/CD variable."
  value       = local.gitlab_oidc_enabled ? aws_iam_role.gitlab_deployer[0].arn : ""
}

output "gitlab_allowed_sub" {
  description = "The resolved OIDC sub pattern a CI job must match to assume the role."
  value       = local.gitlab_oidc_enabled ? local.gitlab_allowed_sub : ""
}

###############################################################################
# Assumed deployer-role outputs (only populated when enable_deployer_role = true)
###############################################################################

output "deployer_role_arn" {
  description = "ARN of the assumable deployer role. Pass to `aws sts assume-role --role-arn`, or set as the provider assume_role.role_arn."
  value       = local.deployer_role_enabled ? aws_iam_role.deployer_role[0].arn : ""
}

output "deployer_role_trust_principals" {
  description = "Principals currently allowed to assume the deployer role."
  value       = local.deployer_role_enabled ? var.deployer_trust_principals : []
}
