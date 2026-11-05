# =============================================================================
# Qdrant (AI 서버 모니터링 봇의 벡터 검색 인덱스) — issues/ai-qdrant-setup.md
#
#   구성 : 단일 EC2 + Docker(qdrant/qdrant:<고정 태그>) + 별도 EBS, 인스턴스는 var.qdrant_instances로 선언
#          기본값 = nonprod(dev·stg 공용) 1대. prod는 아직 두지 않는다(qdrant_instances·ai_monitor_stages에 추가하면 생성). 컬렉션은 앱이 <stage>_knowledge·<stage>_docs·<stage>_chat으로 직접 만든다.
#   원본 저장소 : knowledge·docs는 Qdrant가 원본이다(초기 지식·저장소 문서는 자동 재적재되지만 대화로 저장한 지식·관리자가
#          올린 문서는 스냅샷으로만 복구). chat만 MySQL 원본이라 자동 재적재된다. 그래서 스냅샷과 prevent_destroy는 필수다.
#          장애 시 API 영향은 없다(지식은 이미지 안 seed.json으로 대체, 문서·대화 검색은 대체 경로 없음).
#          dev·stg가 볼륨을 공유하므로 볼륨을 복구하면 두 스테이지가 함께 되돌아간다.
#   접근 : TCP 6333만, 같은 스테이지 fastapi 태스크 SG에서만. 6334(gRPC)·퍼블릭 IP·SSH 없음 (접속은 SSM Session Manager).
#   인증 : API 키 필수. 키는 /<config_path_prefix>/<stage>/ai/AI_QDRANT_API_KEY (ssm.tf, 값은 콘솔 입력)를
#          인스턴스가 부팅 시 읽는다. 인스턴스가 여러 스테이지를 받으면 "첫 번째 스테이지"의 파라미터가 원본이고
#          나머지 스테이지 파라미터에는 같은 값을 넣는다. prod는 별도 인스턴스·별도 키라서 dev·stg 키가 유출돼도 prod 컬렉션에 닿지 않는다.
#   백업 : EBS 일일 스냅샷(DLM, 기본 14일, 끌 수 없음).
#
#   적용 순서 : terraform apply → 콘솔에서 키 입력(원본 스테이지) → 나머지 스테이지 파라미터에 같은 값 입력
#               → 호스트에서 qdrant-apply (SSM Run Command) → AI_QDRANT_URL 입력(output qdrant_urls) → fastapi 재배포
# =============================================================================

locals {
  # ecs_stages에 없는 스테이지는 제외하고, 남는 스테이지가 없는 인스턴스는 만들지 않는다
  qdrant_active = {
    for k, v in var.qdrant_instances : k => merge(v, {
      stages = [for s in v.stages : s if contains(keys(local.ecs_stages), s)]
    })
    if length([for s in v.stages : s if contains(keys(local.ecs_stages), s)]) > 0
  }

  qdrant_image = "qdrant/qdrant:${var.qdrant_version}"

  # 인스턴스 → API 키 원본 SSM 파라미터 (첫 번째 스테이지)
  qdrant_api_key_params = {
    for k, v in local.qdrant_active : k => "/${var.config_path_prefix}/${v.stages[0]}/ai/AI_QDRANT_API_KEY"
  }

  # 6333 접근을 열 fastapi 태스크 SG (인스턴스 × 스테이지)
  qdrant_client_sgs = merge({}, [
    for ik, i in local.qdrant_active : {
      for s in i.stages : "${ik}-${s}" => {
        instance = ik
        stage    = s
        sg_id    = module.ecs_service["${s}-fastapi"].task_security_group_id
      }
      if contains(keys(local.ecs_service_instances), "${s}-fastapi")
    }
  ]...)
}

# -----------------------------------------------------------------------------
# IAM : SSM 접속 + 자기 API 키 파라미터 읽기만
# -----------------------------------------------------------------------------

resource "aws_iam_role" "qdrant" {
  count = length(local.qdrant_active) > 0 ? 1 : 0

  name                 = "${var.project_name}-qdrant"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume_role.json
  max_session_duration = 3600

  tags = {
    Name = "${var.project_name}-qdrant-role"
  }
}

resource "aws_iam_instance_profile" "qdrant" {
  count = length(local.qdrant_active) > 0 ? 1 : 0

  name = "${var.project_name}-qdrant"
  role = aws_iam_role.qdrant[0].name
}

resource "aws_iam_role_policy_attachment" "qdrant_ssm" {
  count = length(local.qdrant_active) > 0 ? 1 : 0

  role       = aws_iam_role.qdrant[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "qdrant_config" {
  count = length(local.qdrant_active) > 0 ? 1 : 0

  statement {
    sid     = "ReadQdrantApiKey"
    actions = ["ssm:GetParameter"]
    resources = [
      for p in values(local.qdrant_api_key_params) :
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${p}"
    ]
  }

  statement {
    sid       = "DecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "qdrant_config" {
  count = length(local.qdrant_active) > 0 ? 1 : 0

  name   = "read-qdrant-api-key"
  role   = aws_iam_role.qdrant[0].id
  policy = data.aws_iam_policy_document.qdrant_config[0].json
}

# -----------------------------------------------------------------------------
# 보안그룹 : 인바운드는 같은 스테이지 fastapi 태스크 SG → 6333 뿐
# -----------------------------------------------------------------------------

resource "aws_security_group" "qdrant" {
  for_each = local.qdrant_active

  name                   = "${var.project_name}-qdrant-${each.key}"
  description            = "Qdrant (${each.key}); 6333 from fastapi task SGs only, access via SSM"
  vpc_id                 = data.aws_vpc.shared.id
  revoke_rules_on_delete = true

  egress {
    description = "Image registry and package repositories through NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-qdrant-${each.key}-sg"
    Tier = "private-data"
  }
}

resource "aws_vpc_security_group_ingress_rule" "qdrant_from_fastapi" {
  for_each = local.qdrant_client_sgs

  security_group_id            = aws_security_group.qdrant[each.value.instance].id
  description                  = "Qdrant REST 6333 from ${each.value.stage}-fastapi tasks"
  referenced_security_group_id = each.value.sg_id
  ip_protocol                  = "tcp"
  from_port                    = 6333
  to_port                      = 6333

  tags = {
    Stage = each.value.stage
  }
}

# -----------------------------------------------------------------------------
# 인스턴스 + 데이터 EBS
#   NAT 경로가 필요하므로(이미지 pull) private 워크로드 서브넷(app·dev)에 둔다.
# -----------------------------------------------------------------------------

resource "aws_instance" "qdrant" {
  for_each = local.qdrant_active

  ami                         = data.aws_ssm_parameter.ubuntu_24_04_x86_64.value
  instance_type               = each.value.instance_type
  subnet_id                   = aws_subnet.v2[each.value.subnet_key].id
  private_ip                  = each.value.private_ip
  vpc_security_group_ids      = [aws_security_group.qdrant[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.qdrant[0].name
  associate_public_ip_address = false
  monitoring                  = false
  ebs_optimized               = true

  user_data = templatefile("${path.module}/templates/qdrant/user_data.sh.tftpl", {
    aws_region    = var.aws_region
    api_key_param = local.qdrant_api_key_params[each.key]
    qdrant_image  = local.qdrant_image
  })
  user_data_replace_on_change = false

  # 데이터 호스트라서 AMI·user_data 변경으로 교체되지 않게 한다 (compute.tf host와 같은 사유).
  # 교체하려면: terraform apply -replace='aws_instance.qdrant["<key>"]'
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.project_name}-qdrant-${each.key}"
    Role        = "qdrant"
    Environment = each.key
    Stages      = join(",", each.value.stages)
  }
}

resource "aws_ebs_volume" "qdrant_data" {
  for_each = local.qdrant_active

  availability_zone = aws_subnet.v2[each.value.subnet_key].availability_zone
  type              = "gp3"
  size              = each.value.data_gib
  iops              = 3000
  throughput        = 125
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name      = "${var.project_name}-qdrant-${each.key}-data"
    DataClass = "persistent"
    Snapshot  = "qdrant"
  }
}

resource "aws_volume_attachment" "qdrant_data" {
  for_each = local.qdrant_active

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.qdrant_data[each.key].id
  instance_id = aws_instance.qdrant[each.key].id
}

# -----------------------------------------------------------------------------
# 일일 스냅샷 (필수: knowledge·docs의 대화/관리자 입력분은 스냅샷으로만 복구된다)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "qdrant_dlm" {
  count = length(local.qdrant_active) > 0 ? 1 : 0

  name               = "${var.project_name}-qdrant-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "qdrant_dlm" {
  count = length(aws_iam_role.qdrant_dlm)

  role       = aws_iam_role.qdrant_dlm[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "qdrant" {
  count = length(aws_iam_role.qdrant_dlm)

  description        = "Qdrant data volume daily snapshot"
  execution_role_arn = aws_iam_role.qdrant_dlm[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "qdrant" }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["18:00"] # 03:00 KST
      }

      retain_rule {
        count = var.qdrant_snapshot_retain_days
      }

      copy_tags = true
    }
  }

  depends_on = [aws_iam_role_policy_attachment.qdrant_dlm]
}

# -----------------------------------------------------------------------------
# 출력 : AI_QDRANT_URL 파라미터에 넣을 값
# -----------------------------------------------------------------------------

output "qdrant_urls" {
  description = "스테이지별 AI_QDRANT_URL 값 (VPC 내부 HTTP). 값은 /<config_path_prefix>/<stage>/ai/AI_QDRANT_URL에 콘솔로 입력한다."
  value = merge({}, [
    for k, i in local.qdrant_active : {
      for s in i.stages : s => "http://${aws_instance.qdrant[k].private_ip}:6333"
    }
  ]...)
}

output "qdrant_instances" {
  description = "Qdrant 인스턴스 ID·사설 IP. 접속: aws ssm start-session --target <instance_id>"
  value = {
    for k, i in aws_instance.qdrant : k => {
      instance_id = i.id
      private_ip  = i.private_ip
      stages      = local.qdrant_active[k].stages
      image       = local.qdrant_image
    }
  }
}
