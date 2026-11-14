# v4 전용 private 서브넷과 라우팅 테이블. V2 라우팅 테이블은 건드리지 않는다.
# 앱 호스트(Spot)는 2a·2c 두 서브넷에, 데이터 호스트는 2a 서브넷에 둔다.
# 기본 경로는 당분간 V2 NAT Gateway를 쓴다. NAT 인스턴스 전환은 별도 작업(설계 V4-13)이다.

resource "aws_subnet" "app" {
  for_each = var.app_subnet_cidrs

  vpc_id                  = data.aws_vpc.shared.id
  cidr_block              = each.value
  availability_zone       = local.azs[each.key]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-app-${each.key}"
    Tier = "private-v4"
  }
}

resource "aws_route_table" "app" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "${local.name_prefix}-app-rt"
  }
}

resource "aws_route" "app_default" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = data.aws_nat_gateway.v2.id
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id

  depends_on = [aws_route.app_default]
}

# ECR 이미지 레이어와 앱 이미지 버킷 트래픽을 NAT 대신 S3 Gateway Endpoint로 보낸다.
# V2의 aws_vpc_endpoint.s3는 route_table_ids를 직접 관리한다. V2 apply로 이 연결이 빠지면 S3 트래픽은 NAT로 우회한다.
resource "aws_vpc_endpoint_route_table_association" "s3_app" {
  vpc_endpoint_id = data.aws_vpc_endpoint.s3.id
  route_table_id  = aws_route_table.app.id
}
