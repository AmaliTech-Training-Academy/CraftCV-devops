# ---------------------------------------------------------------------------
# CI for CraftCV-frontend
#
# The same shape as the backend project, with two deliberate differences:
#
#   * No privileged_mode and no Docker. The frontend has no Dockerfile, so
#     there is nothing to build an image from and no reason to pay for a
#     privileged container.
#   * A much smaller role. This project only reads source and writes logs -
#     no ECR, no SSM, no deployment. It does not deploy anything.
#
# GitHub credentials come from the account-level source credential already
# registered in codebuild.tf; CodeBuild uses one per server type per region.
# ---------------------------------------------------------------------------

locals {
  frontend_project_name = "${var.project_name}-frontend-ci"
  frontend_log_group    = "/aws/codebuild/${var.project_name}-frontend-ci"
}

resource "aws_cloudwatch_log_group" "frontend_ci" {
  name              = local.frontend_log_group
  retention_in_days = 30

  tags = {
    Name = local.frontend_log_group
  }
}

resource "aws_iam_role" "frontend_ci" {
  name = "${var.project_name}-frontend-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:project/${local.frontend_project_name}"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-frontend-codebuild-role"
  }
}

resource "aws_iam_role_policy" "frontend_ci" {
  name = "${var.project_name}-frontend-codebuild-policy"
  role = aws_iam_role.frontend_ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteBuildLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          aws_cloudwatch_log_group.frontend_ci.arn,
          "${aws_cloudwatch_log_group.frontend_ci.arn}:*"
        ]
      },
      {
        Sid    = "PublishTestReports"
        Effect = "Allow"
        Action = [
          "codebuild:CreateReportGroup",
          "codebuild:CreateReport",
          "codebuild:UpdateReport",
          "codebuild:BatchPutTestCases",
          "codebuild:BatchPutCodeCoverages"
        ]
        Resource = "arn:aws:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:report-group/${local.frontend_project_name}-*"
      },
      {
        Sid    = "ReadGitHubToken"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = data.aws_secretsmanager_secret.github_token.arn
      }
    ]
  })
}

resource "aws_codebuild_project" "frontend_ci" {
  name          = local.frontend_project_name
  description   = "Quality gates for ${var.github_owner}/${var.github_frontend_repo}"
  service_role  = aws_iam_role.frontend_ci.arn
  build_timeout = 20

  concurrent_build_limit = 2

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:8.0"
    image_pull_credentials_type = "CODEBUILD"
    # No Docker here, so no privileged container.
    privileged_mode = false

    # Consumed by the deploy step in buildspec.yml.
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = data.aws_region.current.name
    }
    environment_variable {
      name  = "DEPLOY_DOCUMENT_NAME"
      value = aws_ssm_document.deploy_frontend.name
    }
    environment_variable {
      name  = "DEPLOY_INSTANCE_ID"
      value = aws_instance.craftcv_app.id
    }
    environment_variable {
      name  = "DEPLOY_BRANCH"
      value = var.github_default_branch
    }
    environment_variable {
      name  = "ARTIFACT_BUCKET"
      value = aws_s3_bucket.frontend_artifacts.id
    }
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_SOURCE_CACHE", "LOCAL_CUSTOM_CACHE"]
  }

  source {
    type                = "GITHUB"
    location            = "https://github.com/${var.github_owner}/${var.github_frontend_repo}.git"
    buildspec           = "buildspec.yml"
    report_build_status = true

    # Full history: the convention checks compare a pull request against its
    # base branch, which a shallow clone cannot do.
    git_clone_depth = 0
  }

  source_version = var.github_default_branch

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.frontend_ci.name
      stream_name = "build"
    }
  }

  tags = {
    Name = local.frontend_project_name
  }
}

resource "aws_codebuild_webhook" "frontend_ci" {
  project_name = aws_codebuild_project.frontend_ci.name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = local.ci_branch_regex
    }
  }

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PULL_REQUEST_CREATED,PULL_REQUEST_UPDATED,PULL_REQUEST_REOPENED"
    }
    filter {
      type    = "BASE_REF"
      pattern = local.ci_branch_regex
    }
  }
}
