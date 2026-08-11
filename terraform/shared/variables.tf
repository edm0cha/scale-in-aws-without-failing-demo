variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Used as a prefix for resource names"
  type        = string
  default     = "shared"
}

variable "project_name" {
  description = "Project name used as a prefix for all resource names"
  type        = string
  default     = "scale-in-aws-without-failing-demo"
}

variable "organization" {
  type    = string
  default = "edm0cha"
}

variable "repository" {
  type    = string
  default = "scale-in-aws-without-failing-demo"
}
