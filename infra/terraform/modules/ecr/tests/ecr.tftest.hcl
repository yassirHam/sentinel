mock_provider "aws" {}

variables {
  namespace    = "sentinel"
  repositories = ["sample-service", "orion-inference"]
}

run "repositories_are_immutable_scanned_encrypted" {
  command = plan

  assert {
    condition     = toset([for r in aws_ecr_repository.this : r.name]) == toset(["sentinel/sample-service", "sentinel/orion-inference"])
    error_message = "repositories must be namespaced"
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_tag_mutability == "IMMUTABLE"])
    error_message = "tags must be immutable"
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_scanning_configuration[0].scan_on_push])
    error_message = "scan on push must be enabled"
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.encryption_configuration[0].encryption_type == "KMS"])
    error_message = "KMS encryption required"
  }
  assert {
    condition     = alltrue([for p in aws_ecr_lifecycle_policy.this : length(jsondecode(p.policy).rules) == 2])
    error_message = "lifecycle policy must expire untagged and cap tagged images"
  }
}
