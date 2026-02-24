###############################################################################
# VPC Module — Network Foundation
# ──────────────────────────────────────────────────────────────────────────────
# Design decisions:
#   • 2 AZs for HA; easily extensible to 3 by adding CIDR blocks.
#   • Public subnets host NAT GW + ALB (future). Private subnets host Lambda
#     ENIs and RDS.  This isolation guarantees RDS is never internet-routable.
#   • A single NAT GW is used in dev to save cost; for prod, deploy one per AZ
#     by parameterising the count.
#   • DNS hostnames enabled for private hosted zone resolution (RDS endpoints).
#   • /16 VPC CIDR gives ~65k IPs — room for growth without re-IP.
#   • Each subnet is /24 (251 usable IPs), sized for Lambda burst ENI demand.
###############################################################################

# ---------- data sources --------------------------------------------------- #
data "aws_availability_zones" "available" {
  state = "available"
}

# ---------- VPC ------------------------------------------------------------ #
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpc"
  })
}

# ---------- Internet Gateway ----------------------------------------------- #
# Required for public subnet internet egress and NAT GW placement.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-igw"
  })
}

# ---------- Public Subnets ------------------------------------------------- #
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-public-${data.aws_availability_zones.available.names[count.index]}"
    Tier = "public"
  })
}

# ---------- Private Subnets ------------------------------------------------ #
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-private-${data.aws_availability_zones.available.names[count.index]}"
    Tier = "private"
  })
}

# ---------- Elastic IP for NAT Gateway ------------------------------------- #
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-nat-eip"
  })

  depends_on = [aws_internet_gateway.main]
}

# ---------- NAT Gateway ---------------------------------------------------- #
# Placed in the FIRST public subnet.  In prod, create one per AZ.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

# ---------- Route Tables --------------------------------------------------- #

# Public route table — default route via IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table — default route via NAT GW (allows Lambda to call AWS
# APIs and external services while remaining unreachable from the internet)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-private-rt"
  })
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------- Security Groups ------------------------------------------------ #

# Lambda SG — allows ALL outbound (needs AWS API + NAT) but NO inbound from
# the internet.  Inbound is constrained to VPC-internal traffic only.
resource "aws_security_group" "lambda" {
  name_prefix = "${var.project}-${var.environment}-lambda-"
  description = "Security group for Lambda functions inside the VPC"
  vpc_id      = aws_vpc.main.id

  # Outbound: allow all (Lambda needs to call RDS, SQS, S3, external APIs)
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-lambda-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# RDS SG — only accepts traffic from the Lambda SG on the Postgres port.
# Zero public exposure by design.
resource "aws_security_group" "rds" {
  name_prefix = "${var.project}-${var.environment}-rds-"
  description = "Security group for RDS — allows ingress only from Lambda SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  # No egress rule needed for RDS (responses are stateful), but Terraform
  # requires at least one egress or it defaults to "allow all".  Explicitly
  # restrict to VPC CIDR for defense-in-depth.
  egress {
    description = "Allow responses within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------- DB Subnet Group ------------------------------------------------ #
# RDS requires a subnet group spanning ≥2 AZs for Multi-AZ failover.
resource "aws_db_subnet_group" "main" {
  name        = "${var.project}-${var.environment}-db-subnet-group"
  description = "DB subnet group spanning private subnets only"
  subnet_ids  = aws_subnet.private[*].id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-db-subnet-group"
  })
}
