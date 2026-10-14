# =============================================================================
# 모니터링 호스트 (EC2 1대, ECS 클러스터 밖)
#   - Amazon Linux 2023: SSM Agent·AWS CLI가 기본 포함 → 설정 동기화·Session Manager 접속
#   - 데이터 EBS 분리: 인스턴스를 교체해도 Prometheus TSDB·Grafana DB가 남는다 (로그 블록은 S3)
#   - IMDSv2 필수, hop limit 2: 컨테이너(Loki S3, Grafana CloudWatch)가 인스턴스 Role 자격 증명을 쓴다
#   - 공인 IP 없음. 접속은 SSM, Grafana는 Non-Prod ALB 호스트 규칙 또는 SSM 포트 포워딩
# =============================================================================

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size_gib
  type              = "gp3"
  encrypted         = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-monitoring-data"
  })
}

resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.al2023.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = false
  monitoring                  = false
  ebs_optimized               = true

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    data_volume_id         = aws_ebs_volume.data.id
    docker_compose_version = var.docker_compose_version
    sync_env_b64 = base64encode(join("\n", [
      "CONFIG_BUCKET=${aws_s3_bucket.this["config"].bucket}",
      "AWS_REGION=${local.region}",
      "SSM_PATH=${local.ssm_path}",
      "HEARTBEAT_NAMESPACE=${local.heartbeat_namespace}",
      "DATA_DIR=${local.data_dir}",
      "",
    ]))
    sync_script_b64 = base64encode(file("${path.module}/templates/sync.sh"))
  })
  # 설정 변경은 S3 설정 버킷 → 1분 주기 동기화로 반영한다. user data는 부트스트랩만 담당한다.
  user_data_replace_on_change = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-monitoring"
  })

  lifecycle {
    # 최신 AMI가 나올 때마다 호스트가 교체되지 않도록 한다 (교체는 의도적으로 taint/replace)
    ignore_changes = [ami]
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.host.id
  stop_instance_before_detaching = true
}
