terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
  }

  # No backend block on purpose: the first apply runs with local state because
  # the state bucket does not exist yet. Afterwards copy backend.tf.example to
  # backend.tf and run `terraform init -migrate-state` (see README).
}
