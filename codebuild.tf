# ---------------------------------------------------------------------------
# Phase 5: CI in AWS CodeBuild
#
# The flow this file wires up:
#   GitHub (CraftCV-backend) --webhook--> CodeBuild project (eu-west-1)
#       -> runs buildspec.yml -> quality gates -> docker build -> push to ECR
#
# GitHub access comes from a personal access token held in Secrets Manager
# (see the note on credentials below), and AWS access comes from the CodeBuild
# service role.
# ---------------------------------------------------------------------------

# These lookups give us the account ID and region so IAM policies can be
# scoped to exact ARNs instead of "*".
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  codebuild_project_name = "${var.project_name}-backend-ci"
  codebuild_log_group    = "/aws/codebuild/${var.project_name}-backend-ci"

  github_repo_url = "https://github.com/${var.github_owner}/${var.github_repo}.git"

  # One regex covering every branch CI watches, used by both webhook filters.
  ci_branch_regex = "^refs/heads/(${join("|", var.github_ci_branches)})$"
}

# ---------------------------------------------------------------------------
# GitHub credentials
#
# CodeBuild needs GitHub credentials for two things: registering the webhook,
# and cloning the repository on every build.
#
# The organization-approved method is a CodeConnections GitHub App connection,
# which is what this originally used. Installing that app into
# AmaliTech-Training-Academy requires an organization owner, which we do not
# have, and AWS refuses to create the webhook while the connection is PENDING.
#
# So we fall back to a personal access token held in Secrets Manager.
# auth_type SECRETS_MANAGER means Terraform only ever references the secret's
# ARN - the token itself never enters the configuration, the state file or the
# repository, and rotating it is an update to the secret with no Terraform run.
#
# The tradeoff is real and worth writing down: a PAT belongs to a person, so
# CI breaks if that account is deprovisioned or the token expires. Prefer a
# machine account's token, and move back to a connection if an owner ever
# approves the app.
# ---------------------------------------------------------------------------

# Looked up rather than created: the secret is written out of band so the token
# is never passed through Terraform. See README.
data "aws_secretsmanager_secret" "github_token" {
  name = var.github_token_secret_name
}

resource "aws_codebuild_source_credential" "github" {
  auth_type   = "SECRETS_MANAGER"
  server_type = "GITHUB"
  token       = data.aws_secretsmanager_secret.github_token.arn
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
# reading the GitHub token) plus the SSM calls the deploy step in the next
# phase will need - and nothing else.
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

      # --- Reading the GitHub token to clone the source --------------------
      {
        Sid    = "ReadGitHubToken"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = data.aws_secretsmanager_secret.github_token.arn
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
  # build container with the Docker daemon available. standard:8.0 is chosen
  # over 7.0 for Python 3.12, matching the app's Dockerfile, its Actions
  # workflow and target-version in its pyproject.toml.
  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:8.0"
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

  source_version = var.github_default_branch

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
# Builds on every push to develop or main, and on every pull request
# targeting either - the same triggers as the repo's Actions workflow.
# The credential must exist first or CodeBuild cannot register the hook.
# ---------------------------------------------------------------------------

resource "aws_codebuild_webhook" "backend_ci" {
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

  depends_on = [aws_codebuild_source_credential.github]
}
