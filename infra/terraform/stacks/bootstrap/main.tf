###############################################################################
# Stack: bootstrap  (applied ONCE per AWS account, by a human administrator)
#
# Creates what CI itself depends on, so CI can never modify it:
#   * KMS key + S3 bucket holding every other stack's Terraform state
#     (S3-native locking via `use_lockfile`; no DynamoDB table needed)
#   * shared ECR repositories (images are built once and promoted dev -> prod
#     by digest, never rebuilt per environment)
#   * GitHub OIDC provider + the three CI roles
#
# First apply uses local state; then migrate it into the bucket it created:
#   terraform init && terraform apply
#   terraform init -migrate-state -backend-config=../../envs/bootstrap.s3.tfbackend
###############################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  tags = {
    Project    = "sentinel"
    Stack      = "bootstrap"
    ManagedBy  = "terraform"
    Owner      = var.owner
    Repository = var.github_repository
  }
}

resource "aws_kms_key" "state" {
  description             = "Sentinel Terraform state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "state" {
  name          = "alias/sentinel-terraform-state"
  target_key_id = aws_kms_key.state.key_id
}

module "state_bucket" {
  source = "../../modules/s3-bucket"

  name                               = "sentinel-tfstate-${local.account_id}-${var.region}"
  kms_key_arn                        = aws_kms_key.state.arn
  noncurrent_version_expiration_days = 365 # state history is cheap and valuable
}

resource "aws_kms_key" "ecr" {
  description             = "Sentinel container images"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/sentinel-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

module "ecr" {
  source = "../../modules/ecr"

  namespace    = "sentinel"
  repositories = var.ecr_repositories
  kms_key_arn  = aws_kms_key.ecr.arn
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  github_repository    = var.github_repository
  release_branch       = var.release_branch
  apply_environments   = var.apply_environments
  create_oidc_provider = var.create_github_oidc_provider
  ecr_repository_arns  = module.ecr.repository_arns
  ecr_kms_key_arn      = aws_kms_key.ecr.arn
  state_bucket_arn     = module.state_bucket.arn
  state_kms_key_arn    = aws_kms_key.state.arn
}
