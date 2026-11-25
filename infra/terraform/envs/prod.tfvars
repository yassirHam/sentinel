# Sentinel — prod environment (zonal fault isolation, private endpoints)
environment         = "prod"
region              = "eu-west-3"
vpc_cidr            = "10.41.0.0/16"
az_count            = 3
single_nat_gateway  = false
interface_endpoints = ["ecr.api", "ecr.dkr", "sts", "logs"]
kubernetes_version  = "1.36"

eks_public_endpoint       = false
eks_public_access_cidrs   = []
eks_admin_principal_arns  = []
eks_viewer_principal_arns = []

node_groups = {
  system = {
    instance_types = ["m6i.large"]
    min_size       = 3
    max_size       = 6
    desired_size   = 3
    labels         = { "sentinel.io/pool" = "system" }
  }
  workloads = {
    instance_types = ["m6i.xlarge"]
    min_size       = 2
    max_size       = 10
    desired_size   = 2
    labels         = { "sentinel.io/pool" = "workloads" }
  }
  # Scale-to-zero GPU pool for ORION / vLLM inference (Jalal's LLMOps axis).
  # Tainted so only pods that tolerate nvidia.com/gpu land on it.
  gpu = {
    instance_types = ["g5.xlarge"]
    ami_type       = "AL2023_x86_64_NVIDIA"
    min_size       = 0
    max_size       = 2
    desired_size   = 0
    disk_size_gib  = 100
    labels         = { "sentinel.io/pool" = "gpu" }
    taints         = [{ key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE" }]
  }
}

db_instance_class        = "db.t4g.medium"
db_multi_az              = true
db_backup_retention_days = 14
db_deletion_protection   = true
