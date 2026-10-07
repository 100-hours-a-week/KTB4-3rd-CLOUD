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

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "single_az" {
  allocation_id = aws_eip.nat.id
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
  nat_gateway_id         = aws_nat_gateway.single_az.id
}

resource "aws_route_table_association" "private_workloads" {
  for_each = toset(["app", "dev"])

  subnet_id      = aws_subnet.v2[each.key].id
  route_table_id = aws_route_table.private_workloads.id
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
