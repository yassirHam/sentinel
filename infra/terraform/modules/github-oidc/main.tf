###############################################################################
# GitHub Actions -> AWS federation (no long-lived AWS keys anywhere).
#
# GitHub mints a short-lived OIDC token per job; AWS STS exchanges it for
# 1-hour credentials of a role whose trust policy pins the exact repository
# and *context* (branch, pull request, or protected environment):
#
#   image-publisher   repo:<r>:ref:refs/heads/<branch>      push to ECR only
#   terraform-plan    repo:<r>:pull_request | main branch    read-only + state lock
#   terraform-apply   repo:<r>:environment:<env>            gated by GitHub
#                                                           environment reviewers
#
# The apply role can manage IAM *only* under `managed_iam_path` and is
# explicitly denied any change to the CI roles themselves (which live under a
# different path), so a compromised pipeline cannot grant itself more power.
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  issuer     = "token.actions.githubusercontent.com"
  repo       = var.github_repository
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : (
    "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${local.issuer}"
  )
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.issuer}"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    publisher = ["repo:${local.repo}:ref:refs/heads/${var.release_branch}"]
    plan      = ["repo:${local.repo}:pull_request", "repo:${local.repo}:ref:refs/heads/${var.release_branch}"]
    apply     = [for env in var.apply_environments : "repo:${local.repo}:environment:${env}"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:sub"
      values   = each.value
    }
  }
}

# --------------------------------------------------------------------------- #
# image-publisher                                                             #
# --------------------------------------------------------------------------- #
resource "aws_iam_role" "publisher" {
  name                 = "${var.name_prefix}-image-publisher"
  path                 = var.ci_iam_path
  assume_role_policy   = data.aws_iam_policy_document.trust["publisher"].json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "publisher" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushAndSign"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }
  dynamic "statement" {
    for_each = var.ecr_kms_key_arn == null ? [] : [1]
    content {
      sid       = "EcrKms"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.ecr_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "publisher" {
  name   = "ecr-push"
  role   = aws_iam_role.publisher.id
  policy = data.aws_iam_policy_document.publisher.json
}

# --------------------------------------------------------------------------- #
# terraform-plan                                                              #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "state" {
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
  }
  statement {
    sid       = "StateRead"
    actions   = ["s3:GetObject"]
    resources = ["${var.state_bucket_arn}/*"]
  }
  statement {
    sid       = "StateLock" # S3-native locking: <key>.tflock objects
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/*.tflock"]
  }
  statement {
    sid       = "StateKms"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [var.state_kms_key_arn]
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.name_prefix}-terraform-plan"
  path                 = var.ci_iam_path
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state.json
}

# --------------------------------------------------------------------------- #
# terraform-apply                                                             #
# --------------------------------------------------------------------------- #
resource "aws_iam_role" "apply" {
  count = length(var.apply_environments) > 0 ? 1 : 0

  name                 = "${var.name_prefix}-terraform-apply"
  path                 = var.ci_iam_path
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
  max_session_duration = 3600
  tags                 = var.tags
}

# PowerUserAccess = everything except IAM / Organizations / account settings.
resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  count      = length(aws_iam_role.apply)
  role       = aws_iam_role.apply[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply_iam" {
  statement {
    sid = "ManageWorkloadIam"
    actions = [
      "iam:AttachRolePolicy", "iam:CreateRole", "iam:DeleteRole", "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy", "iam:GetRole", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:ListRolePolicies", "iam:PassRole", "iam:PutRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy", "iam:UpdateRole",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
      "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:TagPolicy",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role${var.managed_iam_path}*",
      "arn:${local.partition}:iam::${local.account_id}:policy${var.managed_iam_path}*",
      "arn:${local.partition}:iam::${local.account_id}:instance-profile${var.managed_iam_path}*",
    ]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "autoscaling.amazonaws.com",
        "elasticloadbalancing.amazonaws.com", "rds.amazonaws.com", "spot.amazonaws.com",
      ]
    }
  }
  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
  statement {
    sid    = "NeverTouchCiRoles"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy", "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy",
      "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:TagRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.ci_iam_path}*"]
  }
}

resource "aws_iam_role_policy" "apply_iam" {
  count  = length(aws_iam_role.apply)
  name   = "scoped-iam"
  role   = aws_iam_role.apply[0].id
  policy = data.aws_iam_policy_document.apply_iam.json
}

resource "aws_iam_role_policy" "apply_state" {
  count  = length(aws_iam_role.apply)
  name   = "terraform-state"
  role   = aws_iam_role.apply[0].id
  policy = data.aws_iam_policy_document.state.json
}
