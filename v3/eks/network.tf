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

data "aws_subnet" "public_b" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-public-b"]
  }
  vpc_id = data.aws_vpc.shared.id
}

data "aws_vpc_endpoint" "s3" {
  vpc_id       = data.aws_vpc.shared.id
  service_name = "com.amazonaws.${var.aws_region}.s3"
}

# 2c 전용 NAT와 라우팅 테이블. 2a 장애 시에도 2c 노드의 외부 통신(ECR, STS, SSM)이 유지된다.
resource "aws_eip" "nat_c" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-c-eip"
  }
}

resource "aws_nat_gateway" "c" {
  allocation_id = aws_eip.nat_c.id
  subnet_id     = data.aws_subnet.public_b.id

  tags = {
    Name = "${local.name_prefix}-nat-c"
  }
}

resource "aws_route_table" "private_c" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "${local.name_prefix}-private-c-rt"
  }
}

resource "aws_route" "private_c_nat" {
  route_table_id         = aws_route_table.private_c.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.c.id
}

# V2의 aws_vpc_endpoint.s3는 route_table_ids를 직접 관리한다. V2 apply로 이 연결이 빠지면 S3 트래픽은 2c NAT로 우회한다.
resource "aws_vpc_endpoint_route_table_association" "s3_private_c" {
  vpc_endpoint_id = data.aws_vpc_endpoint.s3.id
  route_table_id  = aws_route_table.private_c.id
}

# 2c의 앱 노드(prod, system)와 클러스터 ENI가 쓰는 서브넷. 위키에 app-c로 예약된 대역이다.
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
  route_table_id = aws_route_table.private_c.id

  depends_on = [aws_route.private_c_nat]
}

# non-prod 노드의 2c 서브넷. 이름의 dev는 스테이지가 아니라 non-prod(dev·stg) 서브넷을 뜻한다.
resource "aws_subnet" "dev_c" {
  vpc_id                  = data.aws_vpc.shared.id
  cidr_block              = var.dev_subnet_c_cidr
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-dev-c"
    Tier = "private-eks"
  }
}

resource "aws_route_table_association" "dev_c" {
  subnet_id      = aws_subnet.dev_c.id
  route_table_id = aws_route_table.private_c.id

  depends_on = [aws_route.private_c_nat]
}
