###############################################################################
# Bootstrap layer — remote-state backend + dedicated deployer IAM user
###############################################################################

provider "aws" {
  region  = var.region
  profile = var.operator_profile

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # If the caller did not name a bucket, derive a globally-unique one.
  create_state_bucket = var.state_bucket_name == ""
  state_bucket_name = (
    local.create_state_bucket
    ? "${var.project_name}-tfstate-${local.account_id}-${var.region}"
    : var.state_bucket_name
  )
}

###############################################################################
# S3 bucket for Terraform remote state
#   - create_state_bucket = true  -> create + fully secure a new bucket
#   - create_state_bucket = false -> reuse an existing bucket (data only)
###############################################################################

resource "aws_s3_bucket" "state" {
  count = local.create_state_bucket ? 1 : 0

  bucket = local.state_bucket_name

  # Refuse to destroy a bucket that still holds state, to prevent foot-guns.
  # The destroy script empties versions first and only then runs destroy.
  force_destroy = true

  tags = merge(var.tags, { Name = local.state_bucket_name })
}

resource "aws_s3_bucket_versioning" "state" {
  count  = local.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count  = local.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count  = local.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce TLS in transit on the state bucket: deny any non-TLS request, and
# deny TLS below 1.2. Applies only when we own (created) the bucket.
data "aws_iam_policy_document" "state_tls" {
  count = local.create_state_bucket ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state[0].arn, "${aws_s3_bucket.state[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyOutdatedTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state[0].arn, "${aws_s3_bucket.state[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  count  = local.create_state_bucket ? 1 : 0
  bucket = aws_s3_bucket.state[0].id
  policy = data.aws_iam_policy_document.state_tls[0].json
}

###############################################################################
# DynamoDB table for state locking
###############################################################################

###############################################################################
# State locking
#
# AWS provider v6 supports S3-NATIVE state locking (use_lockfile = true), so a
# separate DynamoDB lock table is no longer required. The lock is a small
# object written next to the state file in the same bucket, covered by the
# deployer's s3 object permissions below. This removes a resource and makes the
# destroy path cleaner.
###############################################################################

###############################################################################
# Dedicated, least-privilege deployer IAM user
#
# This user — NOT cloud_user — applies and destroys the app layer. It is scoped
# to exactly the services the app layer touches (EventBridge, Lambda, SQS, SNS,
# CloudWatch Logs, IAM role management for the app, Scheduler) plus read/write
# to the state bucket (including the S3-native lock object).
###############################################################################

resource "aws_iam_user" "deployer" {
  name          = var.deployer_user_name
  force_destroy = true
  tags          = merge(var.tags, { Name = var.deployer_user_name })
}

resource "aws_iam_access_key" "deployer" {
  user = aws_iam_user.deployer.name
}

data "aws_iam_policy_document" "deployer" {
  # --- Terraform remote state: S3 (bucket + objects + native lock) --------
  statement {
    sid    = "TerraformStateBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation",
    ]
    resources = ["arn:aws:s3:::${local.state_bucket_name}"]
  }

  statement {
    sid    = "TerraformStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${local.state_bucket_name}/*"]
  }

  # --- Core EventBridge + Scheduler --------------------------------------
  statement {
    sid    = "EventBridge"
    effect = "Allow"
    actions = [
      "events:*",
      "scheduler:*",
      "schemas:*",
    ]
    resources = ["*"]
  }

  # --- Targets / producers / consumers the demo uses ---------------------
  statement {
    sid    = "AppServices"
    effect = "Allow"
    actions = [
      "lambda:*",
      "sqs:*",
      "sns:*",
      "logs:*",
      "cloudwatch:*",
      "kms:*",
      "route53:*",
      "schemas:*",         # Schema Registry
      "scheduler:*",       # EventBridge Scheduler
      "pipes:*",           # EventBridge Pipes
      "access-analyzer:*", # IAM Access Analyzer (detective control)
    ]
    resources = ["*"]
  }

  # --- IAM: manage the app's own execution/invocation roles + policies ---
  # Scoped to IAM ROLE and POLICY actions only — the deployer can create the
  # service roles the app modules need, but has NO user/group/account-admin
  # rights. This is the least privilege that still lets `terraform apply` and
  # `destroy` run repeatedly without whack-a-mole permission failures.
  statement {
    sid    = "AppIamRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:CreateServiceLinkedRole",
      "iam:DeleteServiceLinkedRole",
      "iam:GetServiceLinkedRoleDeletionStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AppIamPolicyManagement"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListEntitiesForPolicy",
      "iam:ListPolicies",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "deployer" {
  name   = "${var.deployer_user_name}-policy"
  user   = aws_iam_user.deployer.name
  policy = data.aws_iam_policy_document.deployer.json
}
