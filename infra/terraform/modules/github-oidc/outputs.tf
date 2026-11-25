output "image_publisher_role_arn" {
  description = "Role for the CI image build/sign/push job (set as AWS_PUBLISHER_ROLE_ARN repo variable)."
  value       = aws_iam_role.publisher.arn
}

output "terraform_plan_role_arn" {
  description = "Role for terraform plan in CI (AWS_PLAN_ROLE_ARN)."
  value       = aws_iam_role.plan.arn
}

output "terraform_apply_role_arn" {
  description = "Role for terraform apply in protected environments (AWS_APPLY_ROLE_ARN)."
  value       = try(aws_iam_role.apply[0].arn, null)
}
