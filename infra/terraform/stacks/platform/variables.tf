variable "environment" {
  description = "Environment name."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-3"
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "yassir.hamri"
}

variable "vpc_cidr" {
  description = "VPC /16 (non-overlapping across environments so they can be peered later)."
  type        = string
}

variable "az_count" {
  description = "Availability zones."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway across AZs."
  type        = bool
  default     = true
}

variable "interface_endpoints" {
  description = "Interface VPC endpoints."
  type        = list(string)
  default     = []
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.36"
}

variable "eks_public_endpoint" {
  description = "Expose the API publicly (restricted by eks_public_access_cidrs)."
  type        = bool
  default     = false
}

variable "eks_public_access_cidrs" {
  description = "Operator CIDRs allowed on the public API endpoint."
  type        = list(string)
  default     = []
}

variable "eks_admin_principal_arns" {
  description = "IAM principals with cluster-admin."
  type        = list(string)
  default     = []
}

variable "eks_viewer_principal_arns" {
  description = "IAM principals with read-only cluster access."
  type        = list(string)
  default     = []
}

variable "node_groups" {
  description = "Managed node groups (see modules/eks)."
  type = map(object({
    instance_types = list(string)
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gib  = optional(number, 50)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
  }))
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Multi-AZ RDS."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "RDS backup retention (PITR window)."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "RDS deletion protection + final snapshot. Secure default; dev sets false so the environment can be torn down nightly."
  type        = bool
  default     = true
}
