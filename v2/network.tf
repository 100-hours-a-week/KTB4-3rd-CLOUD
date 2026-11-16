# The shared V1 VPC and its Internet Gateway are data sources so this root
# cannot create, replace, or take ownership of those V1 network resources.
data "aws_vpc" "shared" {
  id = var.vpc_id
}

data "aws_internet_gateway" "shared" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.shared.id]
  }
}

resource "aws_subnet" "v2" {
  for_each = local.subnet_specs

  vpc_id                  = data.aws_vpc.shared.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${each.value.label}"
    Tier = each.value.tier
  }
}

# These route tables and associations are V2-owned and attach only to V2
# subnets. Existing V1 subnet associations are left untouched.
resource "aws_route_table" "public" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "${var.project_name}-public-rt"
    Tier = "public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.shared.id
}

resource "aws_route_table_association" "public" {
  for_each = toset(["public_a", "public_b"])

  subnet_id      = aws_subnet.v2[each.key].id
  route_table_id = aws_route_table.public.id
}

# var.private_nat_network_interface_id를 주면 NAT Gateway·EIP를 만들지 않고 private 경로를 그 ENI(v4 NAT 인스턴스)로 보낸다
locals {
  nat_gateway_enabled = var.private_nat_network_interface_id == null
}

moved {
  from = aws_eip.nat
  to   = aws_eip.nat[0]
}

moved {
  from = aws_nat_gateway.single_az
  to   = aws_nat_gateway.single_az[0]
}

resource "aws_eip" "nat" {
  count = local.nat_gateway_enabled ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "single_az" {
  count = local.nat_gateway_enabled ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.v2["public_a"].id

  depends_on = [aws_route.public_internet]

  tags = {
    Name = "${var.project_name}-nat-a"
  }
}

resource "aws_route_table" "private_workloads" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "${var.project_name}-private-workloads-rt"
    Tier = "private-workloads"
  }
}

resource "aws_route" "private_workloads_nat" {
  route_table_id         = aws_route_table.private_workloads.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = local.nat_gateway_enabled ? aws_nat_gateway.single_az[0].id : null
  network_interface_id   = local.nat_gateway_enabled ? null : var.private_nat_network_interface_id
}

resource "aws_route_table_association" "private_workloads" {
  for_each = toset(local.private_workload_subnet_keys)

  subnet_id      = aws_subnet.v2[each.key].id
  route_table_id = aws_route_table.private_workloads.id
}

# S3 Gateway Endpoint: private 워크로드 서브넷의 S3 트래픽(ECR 레이어, 모니터링 로그 블록)을 NAT 대신 VPC 안에서 보낸다.
resource "aws_vpc_endpoint" "s3" {
  count = var.s3_gateway_endpoint_enabled ? 1 : 0

  vpc_id            = data.aws_vpc.shared.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_workloads.id]

  tags = {
    Name = "${var.project_name}-s3-gateway"
  }
}

# Data subnets remain isolated; RDS/Redis resources are not created in this root yet.
resource "aws_route_table" "private_data" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "${var.project_name}-private-data-rt"
    Tier = "private-data"
  }
}

resource "aws_route_table_association" "private_data" {
  for_each = toset(["data_a", "data_b"])

  subnet_id      = aws_subnet.v2[each.key].id
  route_table_id = aws_route_table.private_data.id
}
