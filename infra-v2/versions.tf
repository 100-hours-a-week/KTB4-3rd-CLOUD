terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Keep V2 state separate from the legacy infra/ root.
  backend "local" {
    path = "terraform.tfstate"
  }
}
