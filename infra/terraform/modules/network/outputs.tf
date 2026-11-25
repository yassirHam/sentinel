output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "Availability zones in use."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs (load balancers, NAT)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes and pods)."
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "Isolated database subnet IDs."
  value       = aws_subnet.database[*].id
}

output "private_route_table_ids" {
  description = "Private route table IDs (one per AZ)."
  value       = aws_route_table.private[*].id
}

output "subnet_cidrs" {
  description = "Computed subnet plan, for documentation and tests."
  value = {
    public   = local.public_cidrs
    private  = local.private_cidrs
    database = local.database_cidrs
  }
}

output "nat_gateway_count" {
  description = "Number of NAT gateways created."
  value       = local.nat_count
}
