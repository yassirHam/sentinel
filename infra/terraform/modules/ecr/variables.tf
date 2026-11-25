variable "namespace" {
  description = "Repository prefix, e.g. \"sentinel\" -> sentinel/<repo>."
  type        = string
}

variable "repositories" {
  description = "Image repository names (without namespace)."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for image encryption. null = AWS-managed ECR key."
  type        = string
  default     = null
}

variable "untagged_expiry_days" {
  description = "Days after which untagged images are deleted."
  type        = number
  default     = 7
}

variable "keep_tagged_images" {
  description = "Number of most recent images retained per repository."
  type        = number
  default     = 50
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
