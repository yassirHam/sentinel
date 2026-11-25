###############################################################################
# Sentinel network module
#
# Three-tier VPC across N availability zones:
#   public   /24  internet-facing load balancers, NAT gateways
#   private  /19  EKS nodes and pods (VPC CNI gives every pod a VPC IP, hence
#                 the large range)
#   database /24  RDS only — no route to the internet at all
#
# Address plan for the default 10.40.0.0/16:
#   private  10.40.0.0/19, 10.40.32.0/19, 10.40.64.0/19   (index 0..2 of /19)
#   public   10.40.128.0/24 ..                             (index 128.. of /24)
#   database 10.40.144.0/24 ..                             (index 144.. of /24)
#   10.40.96.0/19 and 10.40.160.0/19+ stay free for growth.
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  private_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 3, i)]
  public_cidrs   = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 8, 128 + i)]
  database_cidrs = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 8, 144 + i)]

  nat_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.az_count) : 0

  cluster_tags = var.cluster_name == null ? {} : {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# CIS AWS 5.4: the default security group must not allow any traffic.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-default-deny" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name })
}

# --------------------------------------------------------------------------- #
# Subnets                                                                     #
# --------------------------------------------------------------------------- #
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # nothing gets a public IP unless it asks

  tags = merge(var.tags, local.cluster_tags, {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, local.cluster_tags, {
    Name                              = "${var.name}-private-${local.azs[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
    }, var.cluster_name == null ? {} : {
    "karpenter.sh/discovery" = var.cluster_name
  })
}

resource "aws_subnet" "database" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.database_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-database-${local.azs[count.index]}"
    Tier = "database"
  })
}

# --------------------------------------------------------------------------- #
# Routing                                                                     #
# --------------------------------------------------------------------------- #
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

# One private route table per AZ so that switching from a single NAT gateway
# (dev, cheap) to one per AZ (prod, zonal fault isolation) is a variable flip.
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count = local.nat_count > 0 ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Database subnets: local VPC route only (no NAT, no IGW).
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-database" })
}

resource "aws_route_table_association" "database" {
  count          = var.az_count
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# --------------------------------------------------------------------------- #
# VPC endpoints                                                               #
# --------------------------------------------------------------------------- #
# S3 gateway endpoint: free, keeps image layers (ECR stores them in S3) and
# MLflow/DVC artefact traffic off the NAT gateway (NAT data is billed per GB).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.private[*].id, [aws_route_table.database.id])
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}

resource "aws_security_group" "endpoints" {
  count = length(var.interface_endpoints) > 0 ? 1 : 0

  name        = "${var.name}-vpce"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = length(var.interface_endpoints) > 0 ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from the VPC"
  cidr_ipv4         = var.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Interface endpoints (ecr.api, ecr.dkr, sts, logs, ...) cost ~7 USD/month per
# AZ each; enabled in prod so that nodes can pull images if NAT is impaired.
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  tags                = merge(var.tags, { Name = "${var.name}-${each.value}" })
}

# --------------------------------------------------------------------------- #
# VPC flow logs (CIS AWS 3.9) — encrypted with a dedicated CMK                #
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "flow_logs_kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc/${var.name}/*"]
    }
  }
}

resource "aws_kms_key" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  description             = "${var.name} VPC flow logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.flow_logs_kms.json
  tags                    = var.tags
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = aws_kms_key.flow_logs[0].arn
  tags              = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name_prefix        = "${var.name}-flow-logs-"
  path               = var.iam_path
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_logs_write" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_write[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60
  tags                     = merge(var.tags, { Name = var.name })
}
