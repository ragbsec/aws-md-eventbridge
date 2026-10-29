###############################################################################
# Bootstrap layer — GitLab CI/CD OIDC federation (production deploy identity)
#
# PURPOSE
#   Replace the long-lived IAM-user access key (fine for the sandbox, NOT for
#   production — gap #3) with a short-lived, federated role GitLab assumes via
#   OIDC. GitLab presents a signed JWT (the CI_JOB_JWT / id_token) to AWS STS
#   AssumeRoleWithWebIdentity; AWS trusts it because of the OIDC provider below,
#   and only for the project/refs named in the trust policy condition.
#
#   Everything here is gated on var.enable_gitlab_oidc (default false) so the
#   sandbox path (access key) is untouched. Turn it on for the real account:
#     terraform apply -var enable_gitlab_oidc=true -var gitlab_project_path=group/project
#
# The role REUSES the same least-privilege policy document as the deployer user
# (data.aws_iam_policy_document.deployer in main.tf) — one source of truth, so
# the CI role and the local user can never drift apart.
###############################################################################

locals {
  gitlab_oidc_enabled = var.enable_gitlab_oidc
  # GitLab's OIDC issuer host (strip scheme for the provider resource `url`).
  gitlab_oidc_host = replace(var.gitlab_url, "https://", "")

  # If the caller did not give an explicit sub pattern, scope to the named
  # project's default branch (main). Requires gitlab_project_path to be set.
  gitlab_allowed_sub = (
    var.gitlab_allowed_sub != ""
    ? var.gitlab_allowed_sub
    : "project_path:${var.gitlab_project_path}:ref_type:branch:ref:main"
  )
}

# ---------------------------------------------------------------------------
# OIDC identity provider for GitLab.
#   - For gitlab.com the issuer is https://gitlab.com.
#   - For self-managed, set var.gitlab_url to your instance URL.
#   - thumbprint_list is required by the API but IGNORED by AWS for well-known
#     OIDC hosts whose certs chain to a public root (AWS verifies the cert
#     chain directly). The value below is the long-lived root-CA thumbprint.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "gitlab" {
  count = local.gitlab_oidc_enabled ? 1 : 0

  url             = var.gitlab_url
  client_id_list  = [var.gitlab_url]
  thumbprint_list = [var.gitlab_oidc_thumbprint]

  tags = merge(var.tags, { Name = "${var.project_name}-gitlab-oidc" })
}

# ---------------------------------------------------------------------------
# Trust policy: only a job from the named project AND an allowed ref may assume
# the role. The `sub` claim looks like:
#   project_path:GROUP/PROJECT:ref_type:branch:ref:main
# We constrain it with a wildcard the user controls via var.gitlab_allowed_sub.
# `aud` must equal the client id (the GitLab URL) — this blocks token reuse
# against a different audience.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "gitlab_assume" {
  count = local.gitlab_oidc_enabled ? 1 : 0

  statement {
    sid     = "GitLabOIDCAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab[0].arn]
    }

    # Audience must match the configured client id.
    condition {
      test     = "StringEquals"
      variable = "${local.gitlab_oidc_host}:aud"
      values   = [var.gitlab_url]
    }

    # Subject must match the allowed project/ref pattern (least privilege:
    # defaults to protected pipelines on the project's default branch).
    condition {
      test     = "StringLike"
      variable = "${local.gitlab_oidc_host}:sub"
      values   = [local.gitlab_allowed_sub]
    }
  }
}

resource "aws_iam_role" "gitlab_deployer" {
  count = local.gitlab_oidc_enabled ? 1 : 0

  name                 = "${var.project_name}-gitlab-deployer"
  assume_role_policy   = data.aws_iam_policy_document.gitlab_assume[0].json
  max_session_duration = var.gitlab_role_max_session

  tags = merge(var.tags, { Name = "${var.project_name}-gitlab-deployer" })
}

# Attach the SAME least-privilege permissions the local deployer user carries.
resource "aws_iam_role_policy" "gitlab_deployer" {
  count = local.gitlab_oidc_enabled ? 1 : 0

  name   = "${var.project_name}-gitlab-deployer-policy"
  role   = aws_iam_role.gitlab_deployer[0].id
  policy = data.aws_iam_policy_document.deployer.json
}
