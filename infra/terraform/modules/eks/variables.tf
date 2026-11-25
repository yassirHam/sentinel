variable "cluster_name" {
  description = "EKS cluster name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,99}$", var.cluster_name))
    error_message = "cluster_name must start with a letter and contain only letters, digits and hyphens (max 100)."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version. Keep within EKS standard support (14 months)."
  type        = string
  default     = "1.36"
}

variable "support_type" {
  description = "STANDARD (cluster auto-upgrades at end of standard support) or EXTENDED (paid)."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.support_type)
    error_message = "support_type must be STANDARD or EXTENDED."
  }
}

variable "subnet_ids" {
  description = "Private subnets for the control-plane ENIs and the nodes (>= 2 AZs)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS needs subnets in at least two availability zones."
  }
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly (restricted by public_access_cidrs). Private access is always on."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Required when endpoint_public_access = true."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the Kubernetes API to 0.0.0.0/0; list explicit operator CIDRs."
  }
}

variable "admin_principal_arns" {
  description = "IAM principals granted cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "viewer_principal_arns" {
  description = "IAM principals granted read-only cluster access."
  type        = list(string)
  default     = []
}

variable "node_groups" {
  description = "Managed node groups keyed by name."
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

  validation {
    condition = alltrue([
      for ng in values(var.node_groups) :
      ng.min_size <= ng.desired_size && ng.desired_size <= ng.max_size
    ])
    error_message = "Each node group needs min_size <= desired_size <= max_size."
  }

  validation {
    condition     = alltrue([for ng in values(var.node_groups) : contains(["ON_DEMAND", "SPOT"], ng.capacity_type)])
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "enable_metrics_server" {
  description = "Install metrics-server as an EKS community add-on (needed by HorizontalPodAutoscalers)."
  type        = bool
  default     = true
}

variable "addon_versions" {
  description = "Pin add-on versions (name => version). Unpinned add-ons use the latest version compatible with the cluster."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "CloudWatch retention for control-plane logs."
  type        = number
  default     = 90
}

variable "iam_path" {
  description = "IAM path for roles created by this module."
  type        = string
  default     = "/sentinel/"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
