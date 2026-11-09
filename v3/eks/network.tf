# V2 리소스는 data source로만 참조한다. 이 root는 V2 네트워크를 소유하지 않는다.
data "aws_vpc" "shared" {
  id = var.vpc_id
}

data "aws_subnet" "app" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-app-a"]
  }
  vpc_id = data.aws_vpc.shared.id
}

data "aws_subnet" "dev" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-dev-a"]
  }
  vpc_id = data.aws_vpc.shared.id
}

data "aws_route_table" "private_workloads" {
  vpc_id = data.aws_vpc.shared.id
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-private-workloads-rt"]
  }
}

# 오늘은 클러스터 ENI용이다. prod 노드는 V2와 같이 2a에 두고, Multi-AZ는 전환 후 진행한다.
resource "aws_subnet" "cluster_c" {
  vpc_id                  = data.aws_vpc.shared.id
  cidr_block              = var.cluster_subnet_c_cidr
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-eks-c"
    Tier = "private-eks"
  }
}

resource "aws_route_table_association" "cluster_c" {
  subnet_id      = aws_subnet.cluster_c.id
  route_table_id = data.aws_route_table.private_workloads.id
}
