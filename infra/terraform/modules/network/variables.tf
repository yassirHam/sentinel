variable "name" {
  description = "Name prefix for every network resource (e.g. sentinel-dev)."
  type        = string
}

variable "cidr_block" {
  description = "VPC IPv4 CIDR. Must be a /16 for the documented address plan."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && endswith(var.cidr_block, "/16")
    error_message = "cidr_block must be a valid /16 (the subnet plan carves /19 and /24 blocks out of it)."
  }
}

variable "az_count" {
  description = "Number of availability zones to span (2-3). EKS requires at least 2."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "cluster_name" {
  description = "EKS cluster that will use this VPC; drives the kubernetes.io/karpenter discovery tags. null = no tags."
  type        = string
  default     = null
}

variable "enable_nat_gateway" {
  description = "Give private subnets outbound internet access through NAT."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (cheap, dev) instead of one per AZ (zonal fault isolation, prod)."
  type        = bool
  default     = true
}

variable "interface_endpoints" {
  description = "AWS services to expose through interface VPC endpoints (e.g. [\"ecr.api\", \"ecr.dkr\", \"sts\"])."
  type        = list(string)
  default     = []
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to an encrypted CloudWatch log group."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "Retention of the flow-log group, in days."
  type        = number
  default     = 90
}

variable "iam_path" {
  description = "IAM path for roles created by this module. The CI apply role is only allowed to manage roles under this path."
  type        = string
  default     = "/sentinel/"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
