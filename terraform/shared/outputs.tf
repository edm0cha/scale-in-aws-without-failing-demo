output "deployer_role_arn" {
  description = "ARN of the IAM role — use this as AWS_ROLE_ARN in the downstream pipeline"
  value       = aws_iam_role.deployer.arn
}

output "deployer_role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.deployer.name
}
