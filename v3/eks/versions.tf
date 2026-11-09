terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # V2 state(infra-v2/terraform.tfstate)와 분리한다. 이 root의 plan·apply가 V2 prod 리소스를 건드리지 않게 한다.
  backend "s3" {
    bucket       = "moyeota-v2-tfstate"
    key          = "infra-v3-eks/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "moyeota"
      Environment = "v3"
      ManagedBy   = "terraform"
      Owner       = "cloud"
      Stack       = "eks"
    }
  }
}
