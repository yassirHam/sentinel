output "endpoint" {
  description = "host:port of the instance."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname of the instance."
  value       = aws_db_instance.this.address
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the RDS-managed master credentials."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Database security group."
  value       = aws_security_group.this.id
}
