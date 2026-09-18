# ---------------------------------------------------------------------------
# Phase 5: CI in AWS CodeBuild
#
# The flow this file wires up:
#   GitHub (CraftCV-backend) --webhook--> CodeBuild project (eu-west-1)
#       -> runs buildspec.yml -> quality gates -> docker build -> push to ECR
#
# Nothing here holds a long-lived credential. GitHub access comes from an
# AWS CodeConnections GitHub App connection, and AWS access comes from the
# CodeBuild service role below.
# ---------------------------------------------------------------------------

# These lookups give us the account ID and region so IAM policies can be
# scoped to exact ARNs instead of "*".
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  codebuild_project_name = "${var.project_name}-backend-ci"
  codebuild_log_group    = "/aws/codebuild/${var.project_name}-backend-ci"

  github_repo_url = "https://github.com/${var.github_owner}/${var.github_repo}.git"
}

# ---------------------------------------------------------------------------
# GitHub connection (the organization-approved method)
#
# A CodeConnections connection is backed by the AWS Connector GitHub App. AWS
# holds the short-lived installation token; no personal access token is stored
# anywhere, so CI does not break when someone leaves the org.
#
# Terraform can only create the connection in PENDING state. A human has to
# complete the GitHub App handshake once in the console - see README.
# ---------------------------------------------------------------------------

resource "aws_codeconnections_connection" "github" {
  name          = "${var.project_name}-github"
  provider_type = "GitHub"

  tags = {
    Name = "${var.project_name}-github"
  }
}

# Registers the connection above as the GitHub credential CodeBuild uses in
# this account/region. Gated because AWS rejects this call while the
# connection is still PENDING - flip the variable after authorizing.
resource "aws_codebuild_source_credential" "github" {
  count = var.github_connection_authorized ? 1 : 0

  auth_type   = "CODECONNECTIONS"
  server_type = "GITHUB"
  token       = aws_codeconnections_connection.github.arn
}

# ---------------------------------------------------------------------------
# Build logs
#
# Created explicitly (rather than letting CodeBuild auto-create it) so that
# retention is set and the IAM policy below can be scoped to this one group.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = local.codebuild_log_group
  retention_in_days = 30

  tags = {
    Name = local.codebuild_log_group
  }
}

# ---------------------------------------------------------------------------
# CodeBuild service role
#
# The trust policy lets only the CodeBuild service assume it. The permissions
# policy grants exactly what the build needs (logs, ECR push, test reports,
# reading the GitHub connection) plus the SSM calls the deploy step in the
# next phase will need - and nothing else.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "codebuild" {
  name = "${var.project_name}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        # Confused-deputy guard: even if this role's ARN leaks, it can only be
        # assumed on behalf of this account's own build project.
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:project/${local.codebuild_project_name}"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-codebuild-role"
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${var.project_name}-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # --- Build logs ------------------------------------------------------
      {
        Sid    = "WriteBuildLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          aws_cloudwatch_log_group.codebuild.arn,
          "${aws_cloudwatch_log_group.codebuild.arn}:*"
        ]
      },

      # --- ECR login -------------------------------------------------------
      # GetAuthorizationToken is an account-level action: it has no resource
      # to scope to, so "*" here is the least privilege AWS allows.
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },

      # --- ECR push/pull, scoped to this one repository --------------------
      {
        Sid    = "EcrPushToAppRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          # Read actions let docker reuse cached layers from previous builds.
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages"
        ]
        Resource = aws_ecr_repository.app.arn
      },

      # --- Test/coverage reports shown in the CodeBuild console ------------
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
        Resource = "arn:aws:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:report-group/${local.codebuild_project_name}-*"
      },

      # --- Reading the GitHub connection to clone the source ---------------
      # Both action namespaces are listed because AWS renamed the service
      # (codestar-connections -> codeconnections) and still authorizes calls
      # under either name depending on the calling service's vintage.
      {
        Sid    = "UseGitHubConnection"
        Effect = "Allow"
        Action = [
          "codeconnections:GetConnection",
          "codeconnections:GetConnectionToken",
          "codeconnections:UseConnection",
          "codestar-connections:GetConnection",
          "codestar-connections:GetConnectionToken",
          "codestar-connections:UseConnection"
        ]
        Resource = [
          aws_codeconnections_connection.github.arn,
          replace(aws_codeconnections_connection.github.arn, ":codeconnections:", ":codestar-connections:")
        ]
      },

      # --- Deployment (next phase) -----------------------------------------
      # Deploys run as an SSM command on the app instance, so there is still
      # no SSH key and no inbound port 22. Scoped to the one instance and the
      # one SSM document we actually invoke.
      {
        Sid    = "DeployViaSsmRunCommand"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.craftcv_app.id}",
          "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"
        ]
      },
      {
        Sid    = "ReadSsmCommandResult"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations"
        ]
        # Command IDs are generated at call time, so they cannot be predicted
        # and written into a policy. SendCommand above is the real control.
        Resource = "*"
      },
      {
        Sid    = "FindAppInstance"
        Effect = "Allow"
        Action = "ec2:DescribeInstances"
        # ec2:DescribeInstances does not support resource-level permissions.
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# The build project
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "backend_ci" {
  name          = local.codebuild_project_name
  description   = "Quality gates + Docker image build for ${var.github_owner}/${var.github_repo}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  # Two at a time: a push to main and a PR build can run together without
  # letting a burst of pushes fan out into an unbounded number of builds.
  concurrent_build_limit = 2

  # CI only validates and publishes an image; there is no build artifact to
  # hand to a downstream pipeline stage.
  artifacts {
    type = "NO_ARTIFACTS"
  }

  # --- Docker support -----------------------------------------------------
  # privileged_mode is what makes "docker build" possible: it starts the
  # build container with the Docker daemon available. The standard:7.0 image
  # already ships the docker CLI and Python 3.11.
  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = data.aws_region.current.name
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "ECR_REPOSITORY_URL"
      value = aws_ecr_repository.app.repository_url
    }
    environment_variable {
      name  = "COVERAGE_MIN"
      value = tostring(var.coverage_min)
    }
  }

  # Local caching only - no S3 bucket to manage. The Docker layer cache makes
  # repeat image builds fast; the custom cache holds the pip download cache
  # declared in buildspec.yml.
  cache {
    type = "LOCAL"
    modes = [
      "LOCAL_DOCKER_LAYER_CACHE",
      "LOCAL_SOURCE_CACHE",
      "LOCAL_CUSTOM_CACHE"
    ]
  }

  source {
    type     = "GITHUB"
    location = local.github_repo_url

    # buildspec.yml is read from the repository root, so the build steps are
    # version-controlled alongside the code they test.
    buildspec = "buildspec.yml"

    # Writes the build result back as a commit status, which is what lets a
    # branch protection rule block a failing PR from merging.
    report_build_status = true

    git_clone_depth = 1
  }

  source_version = var.github_branch

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "build"
    }
  }

  tags = {
    Name = local.codebuild_project_name
  }
}

# ---------------------------------------------------------------------------
# Webhook: what actually makes this continuous integration
#
# Builds on every push to main and on every pull request targeting main.
# Depends on the source credential, so it is gated the same way.
# ---------------------------------------------------------------------------

resource "aws_codebuild_webhook" "backend_ci" {
  count = var.github_connection_authorized ? 1 : 0

  project_name = aws_codebuild_project.backend_ci.name
  build_type   = "BUILD"

  # Each filter_group is OR'd; filters inside one group are AND'd.
  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
    filter {
      type    = "HEAD_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
  }

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PULL_REQUEST_CREATED,PULL_REQUEST_UPDATED,PULL_REQUEST_REOPENED"
    }
    filter {
      type    = "BASE_REF"
      pattern = "^refs/heads/${var.github_branch}$"
    }
  }

  depends_on = [aws_codebuild_source_credential.github]
}
