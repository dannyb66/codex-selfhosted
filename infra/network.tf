# Networking. Either reuse an existing VPC + private subnets (create_network=false, the common
# case), or build a minimal VPC (public + 2 private subnets, NAT, S3 gateway endpoint) so the
# GPU tasks have egress (HuggingFace model pull + ECR). Plus the two security groups that mirror
# the proven awsdev pattern: a host SG on the instances, and an ISOLATED SG that exposes only the
# vLLM port to the host (so the SSM tunnel reaches it; nothing broad, nothing public).

data "aws_availability_zones" "available" {
  state = "available"
}

# ---- Optional: minimal VPC ----
resource "aws_vpc" "this" {
  count                = var.create_network ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  count             = var.create_network ? 1 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.name_prefix}-public-0" }
}

resource "aws_subnet" "private" {
  count             = var.create_network ? 2 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.name_prefix}-private-${count.index}" }
}

resource "aws_eip" "nat" {
  count  = var.create_network ? 1 : 0
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  count         = var.create_network ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name_prefix}-nat" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
}

resource "aws_route_table_association" "public" {
  count          = var.create_network ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }
}

resource "aws_route_table_association" "private" {
  count          = var.create_network ? 2 : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

resource "aws_vpc_endpoint" "s3" {
  count             = var.create_network ? 1 : 0
  vpc_id            = aws_vpc.this[0].id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private[0].id]
  tags              = { Name = "${var.name_prefix}-s3-endpoint" }
}

# ---- Resolve which VPC/subnets to use ----
locals {
  vpc_id     = var.create_network ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = var.create_network ? aws_subnet.private[*].id : var.subnet_ids
}

# ---- Security groups ----
# Host SG: on the GPU instances (and shared onto the task ENI). Egress-all so it can pull the
# image/model; no inbound needed (the SSM tunnel originates from the host, outbound).
resource "aws_security_group" "host" {
  name        = "${var.name_prefix}-host"
  description = "Codex GPU host/cluster SG"
  vpc_id      = local.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name_prefix}-host" }
}

# Isolated endpoint SG: attached to the task ENI alongside the host SG. Exposes ONLY the vLLM
# port, and only to the host SG — so the SSM port-forward (host -> task ENI:port) works, and
# nothing else can reach the model. Never open this to 0.0.0.0/0.
resource "aws_security_group" "endpoint" {
  name        = "${var.name_prefix}-endpoint"
  description = "Codex vLLM endpoint - inbound only from the host SG"
  vpc_id      = local.vpc_id
  ingress {
    description     = "vLLM OpenAI port from the host SG (SSM tunnel)"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.host.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name_prefix}-endpoint" }
}
