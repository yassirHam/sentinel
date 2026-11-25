mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::sentinel-test-bucket" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name        = "sentinel-test-bucket"
  kms_key_arn = "arn:aws:kms:eu-west-3:123456789012:key/abc"
}

run "bucket_is_private_versioned_encrypted" {
  command = apply

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "all four public-access blocks must be on"
  }
  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "versioning required"
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "SSE-KMS required"
  }
  assert {
    condition     = aws_s3_bucket_ownership_controls.this.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled"
  }
  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "force_destroy must default to false"
  }
}

run "policy_denies_plaintext_transport" {
  command = apply

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.this.statement :
      s.sid == "DenyInsecureTransport" && s.effect == "Deny"
    ])
    error_message = "bucket policy must deny non-TLS access"
  }
}

run "rejects_invalid_name" {
  command = plan
  variables {
    name = "Not_A_Valid_Bucket"
  }
  expect_failures = [var.name]
}
