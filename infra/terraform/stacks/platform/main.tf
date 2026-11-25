###############################################################################
# Stack: platform  (one state per environment: dev, prod)
#
#   network  ->  eks  ->  (rds, artefact buckets)
#
#   terraform init -backend-config=../../envs/<env>.s3.tfbackend \
#                  -backend-config="bucket=<TF_STATE_BUCKET>"
#   terraform plan -var-file=../../envs/<env>.tfvars
###############################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  name       = "sentinel-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  tags = {
    Project     = "sentinel"
    Environment = var.environment
    Stack       = "platform"
    ManagedBy   = "terraform"
    Owner       = var.owner
    CostCenter  = "tdia3-sentinel"
  }
}

module "network" {
  source = "../../modules/network"

  name                = local.name
  cidr_block          = var.vpc_cidr
  az_count            = var.az_count
  cluster_name        = local.name
  single_nat_gateway  = var.single_nat_gateway
  interface_endpoints = var.interface_endpoints
}

module "eks" {
  source = "../../modules/eks"

  cluster_name           = local.name
  kubernetes_version     = var.kubernetes_version
  subnet_ids             = module.network.private_subnet_ids
  endpoint_public_access = var.eks_public_endpoint
  public_access_cidrs    = var.eks_public_access_cidrs
  admin_principal_arns   = var.eks_admin_principal_arns
  viewer_principal_arns  = var.eks_viewer_principal_arns
  node_groups            = var.node_groups
}

# --------------------------------------------------------------------------- #
# ML data plane: artefact buckets + metadata database                         #
# --------------------------------------------------------------------------- #
resource "aws_kms_key" "data" {
  description             = "${local.name} ML artefacts and metadata"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "data" {
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

module "artifact_buckets" {
  source   = "../../modules/s3-bucket"
  for_each = toset(["mlflow-artifacts", "dvc-remote"])

  name          = "${local.name}-${each.key}-${local.account_id}"
  kms_key_arn   = aws_kms_key.data.arn
  force_destroy = var.environment != "prod"
}

module "metadata_db" {
  source = "../../modules/rds-postgres"

  identifier              = "${local.name}-mlflow"
  vpc_id                  = module.network.vpc_id
  subnet_ids              = module.network.database_subnet_ids
  allowed_security_groups = { eks = module.eks.cluster_security_group_id }
  kms_key_arn             = aws_kms_key.data.arn
  instance_class          = var.db_instance_class
  multi_az                = var.db_multi_az
  backup_retention_days   = var.db_backup_retention_days
  deletion_protection     = var.db_deletion_protection
  final_snapshot          = var.db_deletion_protection
}
