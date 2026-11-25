# Sentinel — dev environment (cost-optimised, still multi-AZ)
environment        = "dev"
region             = "eu-west-3"
vpc_cidr           = "10.40.0.0/16"
az_count           = 3
single_nat_gateway = true # ~33 USD/month instead of ~100 for three
kubernetes_version = "1.36"

# Private API only. To reach it from a laptop either use SSM port-forwarding
# through a node, or flip the public endpoint on with your /32:
eks_public_endpoint     = false
eks_public_access_cidrs = []

# Fill in after bootstrap (the people/roles allowed to run kubectl):
eks_admin_principal_arns  = []
eks_viewer_principal_arns = []

node_groups = {
  system = {
    instance_types = ["t3.large"]
    min_size       = 2
    max_size       = 3
    desired_size   = 2
    labels         = { "sentinel.io/pool" = "system" }
  }
  workloads = {
    instance_types = ["m6i.large", "m5.large", "m6a.large"]
    capacity_type  = "SPOT" # interruptible, ~60-70% cheaper for stateless pods
    min_size       = 0
    max_size       = 4
    desired_size   = 1
    labels         = { "sentinel.io/pool" = "workloads" }
  }
}

db_instance_class        = "db.t4g.micro"
db_multi_az              = false
db_backup_retention_days = 7
db_deletion_protection   = false # throw-away env: accepted risk, see docs/security.md
