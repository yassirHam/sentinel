# Offline unit tests (no AWS credentials): `terraform test` in modules/network.
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
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-west-3:123456789012:log-group:/aws/vpc/sentinel-test/flow-logs" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/sentinel/flow-logs" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:eu-west-3:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }
}

variables {
  name         = "sentinel-test"
  cluster_name = "sentinel-test"
}

run "address_plan_is_disjoint_and_inside_vpc" {
  command = plan

  assert {
    condition     = output.subnet_cidrs.private == ["10.40.0.0/19", "10.40.32.0/19", "10.40.64.0/19"]
    error_message = "private subnets must be the first three /19 blocks"
  }
  assert {
    condition     = output.subnet_cidrs.public == ["10.40.128.0/24", "10.40.129.0/24", "10.40.130.0/24"]
    error_message = "unexpected public subnet plan"
  }
  assert {
    condition     = output.subnet_cidrs.database == ["10.40.144.0/24", "10.40.145.0/24", "10.40.146.0/24"]
    error_message = "unexpected database subnet plan"
  }
  assert {
    condition = length(distinct(concat(
      output.subnet_cidrs.private, output.subnet_cidrs.public, output.subnet_cidrs.database
    ))) == 9
    error_message = "subnet CIDRs must be unique"
  }
}

run "one_subnet_per_az_with_k8s_tags" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 3 && length(distinct(aws_subnet.private[*].availability_zone)) == 3
    error_message = "one private subnet per AZ expected"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.private : s.tags["kubernetes.io/role/internal-elb"] == "1"])
    error_message = "private subnets need the internal-elb tag for the AWS Load Balancer Controller"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.tags["kubernetes.io/role/elb"] == "1"])
    error_message = "public subnets need the elb tag"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.private : s.tags["karpenter.sh/discovery"] == "sentinel-test"])
    error_message = "private subnets need the Karpenter discovery tag"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "public subnets must not auto-assign public IPs"
  }
}

run "dev_uses_single_nat" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_route.private_nat) == 3
    error_message = "single NAT gateway shared by the three private route tables expected"
  }
}

run "prod_uses_one_nat_per_az" {
  command = plan
  variables {
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "one NAT gateway per AZ expected"
  }
}

run "database_tier_has_no_internet_route" {
  command = apply # route list is computed; mocked apply resolves it

  assert {
    condition     = length(aws_route_table.database.route) == 0
    error_message = "database route table must only have the implicit local route"
  }
}

run "flow_logs_encrypted_and_retained" {
  command = plan

  assert {
    condition     = aws_flow_log.this[0].traffic_type == "ALL"
    error_message = "flow logs must capture ALL traffic"
  }
  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 90
    error_message = "flow log retention must be bounded"
  }
  assert {
    condition     = aws_kms_key.flow_logs[0].enable_key_rotation
    error_message = "flow log key must rotate"
  }
}

run "rejects_non_slash16" {
  command = plan
  variables {
    cidr_block = "10.40.0.0/20"
  }
  expect_failures = [var.cidr_block]
}

run "rejects_single_az" {
  command = plan
  variables {
    az_count = 1
  }
  expect_failures = [var.az_count]
}
