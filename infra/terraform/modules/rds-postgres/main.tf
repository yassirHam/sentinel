###############################################################################
# PostgreSQL on RDS — backend store for MLflow (and later ORION metadata).
#
#   * isolated database subnets, not publicly accessible, ingress only from
#     explicitly listed security groups (the EKS cluster SG)
#   * encrypted storage (CMK), TLS enforced via parameter group
#   * master password generated and rotated by RDS in Secrets Manager —
#     it never appears in Terraform state or variables
#   * automated backups => point-in-time recovery (PITR) inside the window
#   * deletion protection + final snapshot outside throw-away environments
###############################################################################

resource "aws_db_subnet_group" "this" {
  name_prefix = "${var.identifier}-"
  description = "${var.identifier} isolated database subnets"
  subnet_ids  = var.subnet_ids
  tags        = var.tags
}

resource "aws_security_group" "this" {
  name_prefix = "${var.identifier}-db-"
  description = "PostgreSQL access for ${var.identifier}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.identifier}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.identifier}-pg${var.engine_major_version}-"
  family      = "postgres${var.engine_major_version}"
  description = "${var.identifier} hardened parameters"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # log statements slower than 1 s
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = var.engine_major_version
  instance_class = var.instance_class

  db_name                       = var.database_name
  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  allocated_storage     = var.allocated_storage_gib
  max_allocated_storage = var.max_allocated_storage_gib
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az
  network_type           = "IPV4"

  iam_database_authentication_enabled = true
  auto_minor_version_upgrade          = true
  allow_major_version_upgrade         = false

  backup_retention_period  = var.backup_retention_days
  backup_window            = "02:00-03:00"
  maintenance_window       = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.final_snapshot
  final_snapshot_identifier = var.final_snapshot ? "${var.identifier}-final" : null

  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = var.performance_insights
  performance_insights_kms_key_id       = var.performance_insights ? var.kms_key_arn : null
  performance_insights_retention_period = var.performance_insights ? 7 : null

  tags = var.tags
}
