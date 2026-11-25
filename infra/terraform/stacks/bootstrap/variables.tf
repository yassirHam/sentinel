variable "region" {
  description = "AWS region of the shared resources."
  type        = string
  default     = "eu-west-3"
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "yassir.hamri"
}

variable "github_repository" {
  description = "Repository allowed to federate into AWS."
  type        = string
  default     = "yassirHam/sentinel-orion"
}

variable "release_branch" {
  description = "Branch that publishes images."
  type        = string
  default     = "master"
}

variable "apply_environments" {
  description = "GitHub environments allowed to apply Terraform."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "ecr_repositories" {
  description = "Image repositories (sentinel/<name>)."
  type        = list(string)
  default     = ["sample-service", "orion-inference"]
}
