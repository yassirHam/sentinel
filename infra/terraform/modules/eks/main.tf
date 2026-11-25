###############################################################################
# Sentinel EKS module
#
# Security posture (EKS best-practices guide):
#   * API server: private endpoint always on; public endpoint optional and
#     restricted to an explicit CIDR allow-list (never 0.0.0.0/0 by default).
#   * Authentication: EKS access entries only (authentication_mode = "API");
#     no aws-auth ConfigMap and the cluster creator is NOT silently admin.
#   * Kubernetes Secrets envelope-encrypted with a dedicated, rotated KMS key.
#   * All control-plane log types shipped to CloudWatch with retention.
#   * Nodes: private subnets only, IMDSv2 required with hop limit 1 (pods
#     cannot steal the node role), encrypted gp3 root volumes, no SSH key —
#     break-glass access goes through SSM Session Manager.
#   * Workload AWS access via EKS Pod Identity (per service account roles).
#   * upgrade_policy STANDARD: the cluster is never silently billed for
#     extended support; staying current is enforced by cost, not by hope.
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  policy_arn = "arn:${local.partition}:iam::aws:policy"
}

# --------------------------------------------------------------------------- #
# Secrets encryption key                                                      #
# --------------------------------------------------------------------------- #
resource "aws_kms_key" "secrets" {
  description             = "${var.cluster_name} Kubernetes secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# Created before the cluster so retention is ours, not "never expire".
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# --------------------------------------------------------------------------- #
# Control plane                                                               #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name_prefix        = "${var.cluster_name}-cluster-"
  path               = var.iam_path
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "${local.policy_arn}/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "cluster_kms" {
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
    resources = [aws_kms_key.secrets.arn]
  }
}

resource "aws_iam_role_policy" "cluster_kms" {
  name   = "secrets-encryption"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_kms.json
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.secrets.arn
    }
  }

  upgrade_policy {
    support_type = var.support_type
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.endpoint_public_access || length(var.public_access_cidrs) > 0
      error_message = "endpoint_public_access = true requires an explicit public_access_cidrs allow-list (EKS would otherwise default to 0.0.0.0/0)."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
    aws_cloudwatch_log_group.cluster,
  ]
}

# --------------------------------------------------------------------------- #
# Access entries (who may talk to the Kubernetes API)                         #
# --------------------------------------------------------------------------- #
locals {
  access = merge(
    { for arn in var.admin_principal_arns : arn => "AmazonEKSClusterAdminPolicy" },
    { for arn in var.viewer_principal_arns : arn => "AmazonEKSViewPolicy" },
  )
}

resource "aws_eks_access_entry" "this" {
  for_each = local.access

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.access

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.this[each.key].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/${each.value}"

  access_scope {
    type = "cluster"
  }
}

# --------------------------------------------------------------------------- #
# Managed node groups                                                         #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name_prefix        = "${var.cluster_name}-node-"
  path               = var.iam_path
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

# AmazonEKS_CNI_Policy stays on the node role on purpose: moving aws-node to
# Pod Identity creates a bootstrap loop (the identity agent itself needs pod
# networking). Pods cannot reach these credentials because IMDS hop limit = 1.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.node.name
  policy_arn = "${local.policy_arn}/${each.value}"
}

resource "aws_launch_template" "node" {
  for_each = var.node_groups

  name_prefix            = "${var.cluster_name}-${each.key}-"
  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach IMDS
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  ami_type        = each.value.ami_type
  capacity_type   = each.value.capacity_type
  instance_types  = each.value.instance_types
  labels          = merge({ "sentinel.io/node-group" = each.key }, each.value.labels)

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  update_config {
    max_unavailable_percentage = 33
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = var.tags

  # The cluster autoscaler / Karpenter owns the live replica count.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# --------------------------------------------------------------------------- #
# Add-ons                                                                     #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name_prefix        = "${var.cluster_name}-ebs-csi-"
  path               = var.iam_path
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "${local.policy_arn}/service-role/AmazonEBSCSIDriverPolicy"
}

locals {
  # Add-ons that must exist before nodes join (networking + identity agent).
  pre_node_addons = ["vpc-cni", "kube-proxy", "eks-pod-identity-agent"]
  # Add-ons that schedule pods and therefore need nodes.
  post_node_addons = concat(
    ["coredns", "aws-ebs-csi-driver"],
    var.enable_metrics_server ? ["metrics-server"] : [],
  )
}

data "aws_eks_addon_version" "this" {
  for_each = toset(concat(local.pre_node_addons, local.post_node_addons))

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "pre_node" {
  for_each = toset(local.pre_node_addons)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = lookup(var.addon_versions, each.key, data.aws_eks_addon_version.this[each.key].version)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = var.tags
}

resource "aws_eks_addon" "post_node" {
  for_each = toset(local.post_node_addons)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = lookup(var.addon_versions, each.key, data.aws_eks_addon_version.this[each.key].version)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  dynamic "pod_identity_association" {
    for_each = each.key == "aws-ebs-csi-driver" ? [1] : []
    content {
      role_arn        = aws_iam_role.ebs_csi.arn
      service_account = "ebs-csi-controller-sa"
    }
  }

  tags       = var.tags
  depends_on = [aws_eks_node_group.this, aws_eks_addon.pre_node]
}
