variable "name" {
  description = "Globally unique bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.name))
    error_message = "Bucket names must be 3-63 chars of lowercase letters, digits, dots and hyphens."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key used for default encryption (required)."
  type        = string
}

variable "noncurrent_version_expiration_days" {
  description = "Delete non-current object versions after this many days."
  type        = number
  default     = 90
}

variable "access_log_bucket" {
  description = "Bucket receiving server access logs. null = no access logging."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete a non-empty bucket. Keep false outside throw-away envs."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
