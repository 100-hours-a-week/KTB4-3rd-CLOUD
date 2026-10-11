resource "aws_instance" "host" {
  for_each = local.hosts

  ami                         = data.aws_ssm_parameter.ubuntu_24_04_x86_64.value
  instance_type               = each.value.instance_type
  subnet_id                   = aws_subnet.v2[each.value.subnet_key].id
  vpc_security_group_ids      = [each.value.environment == "prod" ? aws_security_group.prod_instances.id : aws_security_group.dev_instance.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false
  monitoring                  = false
  ebs_optimized               = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    project_name           = var.project_name
    environment            = each.value.environment
    aws_region             = var.aws_region
    docker_compose_version = var.docker_compose_version
    mount_data_volume      = each.value.data_volume
  })
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
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.project_name}-${each.key}"
    Environment = each.value.environment
    Role        = each.key
  }
}

resource "aws_ebs_volume" "dev_data" {
  availability_zone = local.az_a
  type              = "gp3"
  size              = var.dev_data_volume_size_gib
  iops              = 3000
  throughput        = 125
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-dev-data"
    Environment = "dev"
    DataClass   = "persistent"
  }
}

resource "aws_volume_attachment" "dev_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.dev_data.id
  instance_id = aws_instance.host["dev"].id
}