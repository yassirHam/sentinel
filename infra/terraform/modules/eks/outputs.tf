output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle of the API server."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Running Kubernetes version."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group EKS attaches to the control plane and managed nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "IAM role of the managed nodes."
  value       = aws_iam_role.node.arn
}

output "secrets_kms_key_arn" {
  description = "KMS key encrypting Kubernetes secrets."
  value       = aws_kms_key.secrets.arn
}

output "kubeconfig_command" {
  description = "Command to fetch a kubeconfig for this cluster."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${data.aws_region.current.region}"
}
