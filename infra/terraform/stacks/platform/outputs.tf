output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "subnet_plan" {
  description = "Subnet CIDRs per tier."
  value       = module.network.subnet_cidrs
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Fetch kubeconfig."
  value       = module.eks.kubeconfig_command
}

output "artifact_buckets" {
  description = "MLflow / DVC buckets."
  value       = { for k, b in module.artifact_buckets : k => b.id }
}

output "metadata_db_endpoint" {
  description = "PostgreSQL endpoint."
  value       = module.metadata_db.endpoint
}

output "metadata_db_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials."
  value       = module.metadata_db.master_user_secret_arn
}
