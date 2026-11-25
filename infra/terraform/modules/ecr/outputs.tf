output "repository_urls" {
  description = "Repository name => URL."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "Repository ARNs (used to scope the CI push role)."
  value       = [for r in aws_ecr_repository.this : r.arn]
}
