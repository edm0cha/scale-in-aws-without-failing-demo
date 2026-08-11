terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    bucket  = "shared-superlab-awsugcdmx-tfstate"
    key     = "shared/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      ManagedBy    = "terraform"
      Environment  = "shared"
      Organization = "edm0cha"
      Repository   = "scale-in-aws-without-failing-demo"
      Customer     = "edm0cha"
      Project      = "scale-in-aws-without-failing-demo"
    }
  }
}
