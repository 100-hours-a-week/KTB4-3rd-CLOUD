provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}

data "aws_partition" "current" {}

data "aws_ssm_parameter" "ubuntu_24_04_x86_64" {
  # Canonical-maintained Ubuntu 24.04 LTS (Noble), x86_64, gp3 AMI.
  name = "/aws/service/canonical/ubuntu/server/noble/stable/current/amd64/hvm/ebs-gp3/ami-id"
}
