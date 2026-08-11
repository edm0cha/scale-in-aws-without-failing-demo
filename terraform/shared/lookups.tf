data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# Reference the existing GitHub OIDC provider already created in the account
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}
