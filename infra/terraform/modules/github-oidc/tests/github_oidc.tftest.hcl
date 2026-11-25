mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  github_repository   = "yassirHam/sentinel-orion"
  ecr_repository_arns = ["arn:aws:ecr:eu-west-3:123456789012:repository/sentinel/sample-service"]
  state_bucket_arn    = "arn:aws:s3:::sentinel-tfstate"
  state_kms_key_arn   = "arn:aws:kms:eu-west-3:123456789012:key/abc"
}

run "trust_policies_pin_repository_and_context" {
  command = plan

  assert {
    condition = one([
      for c in data.aws_iam_policy_document.trust["publisher"].statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"
    ]) == tolist(["repo:yassirHam/sentinel-orion:ref:refs/heads/master"])
    error_message = "publisher may only be assumed from the release branch"
  }
  assert {
    condition = one([
      for c in data.aws_iam_policy_document.trust["apply"].statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"
    ]) == tolist(["repo:yassirHam/sentinel-orion:environment:dev", "repo:yassirHam/sentinel-orion:environment:prod"])
    error_message = "apply may only be assumed from protected environments"
  }
  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust :
      anytrue([for c in d.statement[0].condition : c.variable == "token.actions.githubusercontent.com:aud" && c.values == tolist(["sts.amazonaws.com"])])
    ])
    error_message = "every trust policy must check the audience"
  }
}

run "ci_roles_are_short_lived_and_outside_managed_path" {
  command = plan

  assert {
    condition     = alltrue([for r in [aws_iam_role.publisher, aws_iam_role.plan, aws_iam_role.apply[0]] : r.max_session_duration == 3600 && r.path == "/sentinel-ci/"])
    error_message = "CI roles: 1h sessions under /sentinel-ci/"
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.apply_iam.statement :
      s.sid == "NeverTouchCiRoles" && s.effect == "Deny"
    ])
    error_message = "apply role must be denied changes to the CI roles"
  }
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.publisher.statement :
      s.sid == "EcrLogin" || s.resources == toset(var.ecr_repository_arns) || s.sid == "EcrKms"
    ])
    error_message = "publisher push rights must be scoped to the listed repositories"
  }
}

run "rejects_wildcard_repository" {
  command = plan
  variables {
    github_repository = "yassirHam/*"
  }
  expect_failures = [var.github_repository]
}
