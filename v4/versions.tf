terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # V2(infra-v2), V3(infra-v3-eks) state와 분리한다. 이 root는 V2 리소스를 data source로만 읽는다.
  backend "s3" {
    bucket       = "moyeota-v2-tfstate"
    key          = "infra-v4/terraform.tfstate"
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
      Environment = "v4"
      ManagedBy   = "terraform"
      Owner       = "cloud"
      Stack       = "ecs-min"
    }
  }
}
