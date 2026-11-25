# Offline unit tests for modules/eks (mocked AWS provider).
mock_provider "aws" {
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
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:eu-west-3:123456789012:cluster/sentinel-test"
      certificate_authority = [{ data = "Y2EtZGF0YQ==" }]
    }
  }
}

variables {
  cluster_name = "sentinel-test"
  subnet_ids   = ["subnet-a", "subnet-b", "subnet-c"]
  node_groups = {
    system = { instance_types = ["t3.large"], min_size = 2, max_size = 3, desired_size = 2 }
    gpu = {
      instance_types = ["g5.xlarge"]
      ami_type       = "AL2023_x86_64_NVIDIA"
      min_size       = 0
      max_size       = 2
      desired_size   = 0
      taints         = [{ key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE" }]
    }
  }
  admin_principal_arns = ["arn:aws:iam::123456789012:role/platform-admin"]
}

run "control_plane_is_hardened" {
  command = apply # mocked: resolves computed values without AWS

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access && !aws_eks_cluster.this.vpc_config[0].endpoint_public_access
    error_message = "API must be private by default"
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "access entries only (no aws-auth ConfigMap)"
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "cluster creator must not be implicit admin"
  }
  assert {
    condition     = one(aws_eks_cluster.this.encryption_config[0].resources) == "secrets"
    error_message = "secrets must be envelope-encrypted"
  }
  assert {
    condition     = length(aws_eks_cluster.this.enabled_cluster_log_types) == 5
    error_message = "all five control-plane log types must be enabled"
  }
  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "extended support must be opt-in"
  }
  assert {
    condition     = aws_kms_key.secrets.enable_key_rotation
    error_message = "secrets key must rotate"
  }
}

run "nodes_enforce_imdsv2_and_encrypted_disks" {
  command = apply

  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.metadata_options[0].http_tokens == "required"])
    error_message = "IMDSv2 must be required"
  }
  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.metadata_options[0].http_put_response_hop_limit == 1])
    error_message = "IMDS hop limit must be 1 so pods cannot reach node credentials"
  }
  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.block_device_mappings[0].ebs[0].encrypted == "true"])
    error_message = "node volumes must be encrypted"
  }
  assert {
    condition     = one(aws_eks_node_group.this["gpu"].taint).key == "nvidia.com/gpu"
    error_message = "GPU pool must be tainted"
  }
  assert {
    condition     = aws_eks_node_group.this["gpu"].scaling_config[0].min_size == 0
    error_message = "GPU pool must scale to zero"
  }
}

run "access_entries_and_addons" {
  command = apply

  assert {
    condition     = length(aws_eks_access_entry.this) == 1
    error_message = "one access entry per admin principal"
  }
  assert {
    condition     = endswith(aws_eks_access_policy_association.this["arn:aws:iam::123456789012:role/platform-admin"].policy_arn, "AmazonEKSClusterAdminPolicy")
    error_message = "admins get the cluster-admin access policy"
  }
  assert {
    condition     = toset(keys(aws_eks_addon.pre_node)) == toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])
    error_message = "networking + pod identity add-ons expected before nodes"
  }
  assert {
    condition     = one(aws_eks_addon.post_node["aws-ebs-csi-driver"].pod_identity_association).service_account == "ebs-csi-controller-sa"
    error_message = "EBS CSI driver must use Pod Identity"
  }
}

run "public_endpoint_requires_allow_list" {
  command = plan
  variables {
    endpoint_public_access = true
    public_access_cidrs    = []
  }
  expect_failures = [aws_eks_cluster.this]
}

run "refuses_world_open_api" {
  command = plan
  variables {
    endpoint_public_access = true
    public_access_cidrs    = ["0.0.0.0/0"]
  }
  expect_failures = [var.public_access_cidrs]
}

run "rejects_bad_scaling" {
  command = plan
  variables {
    node_groups = { bad = { instance_types = ["t3.large"], min_size = 3, max_size = 2, desired_size = 2 } }
  }
  expect_failures = [var.node_groups]
}
