variable "identifier" {
  description = "RDS instance identifier."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the database."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated database subnets (>= 2 AZs)."
  type        = list(string)
}

variable "allowed_security_groups" {
  description = "Security groups allowed to connect on 5432, keyed by a static label (e.g. { eks = sg-... }). A map, not a list, so that IDs unknown until apply do not break for_each."
  type        = map(string)
  default     = {}
}

variable "engine_major_version" {
  description = "PostgreSQL major version (minor upgrades are automatic)."
  type        = string
  default     = "17"
}

variable "instance_class" {
  description = "DB instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "database_name" {
  description = "Initial database."
  type        = string
  default     = "mlflow"
}

variable "master_username" {
  description = "Master user name (password is managed by RDS in Secrets Manager)."
  type        = string
  default     = "sentinel_admin"
}

variable "allocated_storage_gib" {
  description = "Initial storage."
  type        = number
  default     = 20
}

variable "max_allocated_storage_gib" {
  description = "Storage autoscaling ceiling."
  type        = number
  default     = 100
}

variable "kms_key_arn" {
  description = "CMK for storage, master secret and Performance Insights."
  type        = string
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention (enables point-in-time recovery). 1-35."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be 1-35 (0 would disable PITR)."
  }
}

variable "deletion_protection" {
  description = "Block accidental deletion."
  type        = bool
  default     = true
}

variable "final_snapshot" {
  description = "Take a final snapshot on destroy."
  type        = bool
  default     = true
}

variable "performance_insights" {
  description = "Enable Performance Insights (7-day free retention)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
