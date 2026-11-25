###############################################################################
# Sentinel ECR module — one private repository per image.
#
# * IMMUTABLE tags: a tag (we use the git SHA) can never be re-pointed, so the
#   digest Argo CD deploys and the digest Cosign signed are always the same.
# * scan on push (basic scanning) as a second opinion next to Trivy in CI.
# * KMS encryption at rest; lifecycle policy bounds storage cost.
###############################################################################

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.namespace}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images (failed pushes, superseded manifests) after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the ${var.keep_tagged_images} most recent tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_tagged_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
