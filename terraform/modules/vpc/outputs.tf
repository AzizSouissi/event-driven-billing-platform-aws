output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "lambda_security_group_id" {
  description = "Security group ID to attach to Lambda functions"
  value       = aws_security_group.lambda.id
}

output "rds_security_group_id" {
  description = "Security group ID to attach to RDS instances"
  value       = aws_security_group.rds.id
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group for RDS placement"
  value       = aws_db_subnet_group.main.name
}

output "nat_gateway_ip" {
  description = "Public IP of the NAT Gateway"
  value       = aws_eip.nat.public_ip
}

output "private_route_table_ids" {
  description = "IDs of private route tables (for Gateway VPC endpoints)"
  value       = [aws_route_table.private.id]
}

output "availability_zones" {
  description = "AZs used by the subnets"
  value       = data.aws_availability_zones.available.names
}
