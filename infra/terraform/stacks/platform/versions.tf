terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
  }

  # Partial configuration: key/region/locking live in envs/<env>.s3.tfbackend,
  # the bucket name (account-specific) is passed with -backend-config.
  backend "s3" {}
}
