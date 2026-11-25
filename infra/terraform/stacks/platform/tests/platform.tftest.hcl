# Composition test: the real dev/prod variable files plan cleanly end-to-end
# against a mocked AWS provider (catches wiring errors between modules).
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-3a", "eu-west-3b", "eu-west-3c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-3" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v0.0.0-eksbuild.1" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:eu-west-3:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/sentinel/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-west-3:123456789012:log-group:mock" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:eu-west-3:123456789012:cluster/mock"
      certificate_authority = [{ data = "Y2E=" }]
    }
  }
  mock_resource "aws_db_instance" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:eu-west-3:123456789012:secret:rds", kms_key_id = "k", secret_status = "active" }] }
  }
}

run "dev" {
  command = apply
  variables {
    environment        = "dev"
    vpc_cidr           = "10.40.0.0/16"
    single_nat_gateway = true
    node_groups = {
      system    = { instance_types = ["t3.large"], min_size = 2, max_size = 3, desired_size = 2 }
      workloads = { instance_types = ["m6i.large"], capacity_type = "SPOT", min_size = 0, max_size = 4, desired_size = 1 }
    }
  }

  assert {
    condition     = output.cluster_name == "sentinel-dev"
    error_message = "cluster name must derive from the environment"
  }
  assert {
    condition     = module.network.nat_gateway_count == 1
    error_message = "dev uses a single NAT gateway"
  }
  assert {
    condition     = module.metadata_db.security_group_id != null && module.artifact_buckets["mlflow-artifacts"].arn != null
    error_message = "database and artefact buckets must be created"
  }
  assert {
    condition     = toset(keys(output.artifact_buckets)) == toset(["mlflow-artifacts", "dvc-remote"])
    error_message = "MLflow and DVC buckets expected"
  }
}

run "prod" {
  command = apply
  variables {
    environment         = "prod"
    vpc_cidr            = "10.41.0.0/16"
    single_nat_gateway  = false
    interface_endpoints = ["ecr.api", "ecr.dkr", "sts", "logs"]
    db_multi_az         = true
    node_groups = {
      system = { instance_types = ["m6i.large"], min_size = 3, max_size = 6, desired_size = 3 }
    }
  }

  assert {
    condition     = module.network.nat_gateway_count == 3
    error_message = "prod uses one NAT gateway per AZ"
  }
  assert {
    condition     = output.subnet_plan.private[0] == "10.41.0.0/19"
    error_message = "prod must not overlap dev"
  }
}

run "rejects_unknown_environment" {
  command = plan
  variables {
    environment = "staging"
    vpc_cidr    = "10.42.0.0/16"
    node_groups = {}
  }
  expect_failures = [var.environment]
}
