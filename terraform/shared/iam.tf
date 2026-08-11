resource "aws_iam_role" "deployer" {
  name               = "${var.prefix}-${var.project_name}-deployer-github-actions"
  assume_role_policy = data.aws_iam_policy_document.deployer.json
}

data "aws_iam_policy_document" "deployer" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.organization}/${var.repository}:*"
      ]
    }
  }
}

resource "aws_iam_policy" "management" {
  name        = "${var.prefix}-${var.project_name}-management-github-actions"
  description = "Permissions for the GitHub Actions pipeline to deploy S3 and CloudFront"
  policy = templatefile("${path.root}/policies/management-github-actions.json", {
    account_id   = data.aws_caller_identity.current.account_id
    project_name = var.project_name
  })
}

resource "aws_iam_role_policy_attachment" "management" {
  role       = aws_iam_role.deployer.name
  policy_arn = aws_iam_policy.management.arn
}

