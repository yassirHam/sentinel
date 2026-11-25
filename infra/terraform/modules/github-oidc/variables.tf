variable "name_prefix" {
  description = "Prefix of the CI role names."
  type        = string
  default     = "sentinel"
}

variable "github_repository" {
  description = "owner/name of the repository allowed to assume the roles."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name (no wildcards)."
  }
}

variable "release_branch" {
  description = "Branch whose workflows may publish images."
  type        = string
  default     = "master"
}

variable "apply_environments" {
  description = "GitHub environments (with required reviewers) allowed to run terraform apply."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "create_oidc_provider" {
  description = "Create the account-wide GitHub OIDC provider (false if it already exists)."
  type        = bool
  default     = true
}

variable "ecr_repository_arns" {
  description = "Repositories the publisher role may push to."
  type        = list(string)
}

variable "ecr_kms_key_arn" {
  description = "CMK of the ECR repositories (null if AWS-managed)."
  type        = string
  default     = null
}

variable "state_bucket_arn" {
  description = "Terraform state bucket ARN."
  type        = string
}

variable "state_kms_key_arn" {
  description = "KMS key encrypting the state bucket."
  type        = string
}

variable "managed_iam_path" {
  description = "IAM path the apply role may manage (workload roles)."
  type        = string
  default     = "/sentinel/"
}

variable "ci_iam_path" {
  description = "IAM path of the CI roles themselves (never manageable by CI)."
  type        = string
  default     = "/sentinel-ci/"

  validation {
    condition     = startswith(var.ci_iam_path, "/") && endswith(var.ci_iam_path, "/")
    error_message = "IAM paths must start and end with '/'."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
