terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
  }

  backend "s3" {
    bucket  = "shared-superlab-scale-in-aws-without-failing-demo-tfstate"
    key     = "terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      ManagedBy    = "terraform"
      Environment  = "demos"
      Organization = "edm0cha"
      Repository   = "scale-in-aws-without-failing-demo"
      Customer     = "edm0cha"
      Project      = "scale-in-aws-without-failing-demo"
    }
  }
}
