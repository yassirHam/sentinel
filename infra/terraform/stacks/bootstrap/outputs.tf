output "state_bucket" {
  description = "Bucket for every other stack's state."
  value       = module.state_bucket.id
}

output "state_kms_key_arn" {
  description = "State encryption key."
  value       = aws_kms_key.state.arn
}

output "ecr_repository_urls" {
  description = "ECR repositories."
  value       = module.ecr.repository_urls
}

output "github_actions_variables" {
  description = "Values to store as GitHub repository variables (not secrets: they are not sensitive)."
  value = {
    AWS_REGION             = var.region
    AWS_PUBLISHER_ROLE_ARN = module.github_oidc.image_publisher_role_arn
    AWS_PLAN_ROLE_ARN      = module.github_oidc.terraform_plan_role_arn
    AWS_APPLY_ROLE_ARN     = module.github_oidc.terraform_apply_role_arn
    ECR_REGISTRY           = split("/", values(module.ecr.repository_urls)[0])[0]
    TF_STATE_BUCKET        = module.state_bucket.id
  }
}
