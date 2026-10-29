###############################################################################
# Bootstrap layer — assumed deployer ROLE (human/CI identities, same account)
#
# PURPOSE
#   The production-grade alternative to the static IAM-user access key: a role
#   that one or more named principals ASSUME to apply/destroy. Proven to work in
#   accounts that permit sts:AssumeRole (verified live in 329863774956).
#
#   Gated on var.enable_deployer_role (default false) so the static-key path is
#   untouched. The trust principals are a configurable LIST — add users or CI
#   identities without rewriting the role. This is how you authorize additional
#   deployers cleanly (least privilege: name each principal; avoid :root).
#
#   The role attaches the SAME least-privilege policy document the deployer USER
#   uses (data.aws_iam_policy_document.deployer in main.tf) — one source of
#   truth across the user, this role, and the GitLab OIDC role.
#
# USAGE
#   terraform apply \
#     -var enable_deployer_role=true \
#     -var 'deployer_trust_principals=["arn:aws:iam::329863774956:user/cloud_user"]'
#   Then assume it:
#     aws sts assume-role \
#       --role-arn <output deployer_role_arn> \
#       --role-session-name deploy
###############################################################################

locals {
  deployer_role_enabled = var.enable_deployer_role

  # Default the trust to the operator-running account root is DISCOURAGED; we
  # require an explicit principals list so the role is never over-trusting.
  deployer_trust_principals = var.deployer_trust_principals
}

data "aws_iam_policy_document" "deployer_role_trust" {
  count = local.deployer_role_enabled ? 1 : 0

  statement {
    sid     = "AllowNamedPrincipalsToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.deployer_trust_principals
    }

    # Optional hardening: require an external id for cross-account use. Empty
    # string disables the condition (same-account human use).
    dynamic "condition" {
      for_each = var.deployer_external_id != "" ? [1] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.deployer_external_id]
      }
    }
  }
}

resource "aws_iam_role" "deployer_role" {
  count = local.deployer_role_enabled ? 1 : 0

  name                 = "${var.deployer_user_name}-role"
  assume_role_policy   = data.aws_iam_policy_document.deployer_role_trust[0].json
  max_session_duration = var.deployer_role_max_session

  tags = merge(var.tags, { Name = "${var.deployer_user_name}-role" })
}

resource "aws_iam_role_policy" "deployer_role" {
  count = local.deployer_role_enabled ? 1 : 0

  name   = "${var.deployer_user_name}-role-policy"
  role   = aws_iam_role.deployer_role[0].id
  policy = data.aws_iam_policy_document.deployer.json
}
