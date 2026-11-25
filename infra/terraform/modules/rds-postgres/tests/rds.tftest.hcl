mock_provider "aws" {}

variables {
  identifier              = "sentinel-test-mlflow"
  vpc_id                  = "vpc-123"
  subnet_ids              = ["subnet-a", "subnet-b"]
  allowed_security_groups = { eks = "sg-eks" }
  kms_key_arn             = "arn:aws:kms:eu-west-3:123456789012:key/abc"
}

run "database_is_private_encrypted_and_recoverable" {
  command = plan

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "database must not be public"
  }
  assert {
    condition     = aws_db_instance.this.storage_encrypted
    error_message = "storage must be encrypted"
  }
  assert {
    condition     = aws_db_instance.this.manage_master_user_password
    error_message = "master password must be managed by RDS/Secrets Manager"
  }
  assert {
    condition     = aws_db_instance.this.backup_retention_period >= 1
    error_message = "backups (PITR) required"
  }
  assert {
    condition     = aws_db_instance.this.deletion_protection
    error_message = "deletion protection must default on"
  }
  assert {
    condition     = anytrue([for p in aws_db_parameter_group.this.parameter : p.name == "rds.force_ssl" && p.value == "1"])
    error_message = "TLS must be enforced"
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.postgres) == 1 && aws_vpc_security_group_ingress_rule.postgres["eks"].from_port == 5432
    error_message = "only the listed security groups may reach 5432"
  }
}

run "pitr_cannot_be_disabled" {
  command = plan
  variables {
    backup_retention_days = 0
  }
  expect_failures = [var.backup_retention_days]
}
