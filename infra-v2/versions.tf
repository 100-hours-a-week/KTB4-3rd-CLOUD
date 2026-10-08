terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Keep V2 state separate from the legacy s3 moyeota-v2-tfstate bucket
  backend "s3" {
    bucket       = "moyeota-v2-tfstate"
    key          = "infra-v2/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}