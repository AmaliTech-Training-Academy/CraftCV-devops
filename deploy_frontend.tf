# ---------------------------------------------------------------------------
# Frontend deployment over SSM
#
# Same shape as the backend deploy: a document wrapping a reviewed script, so
# what runs is version controlled and the build role can be allowed to run
# exactly this and nothing else.
#
# The frontend is generated to static files and served by nginx from the same
# origin as the API, so no server address is ever baked into the bundle. That
# is what keeps it working after the sandbox restarts on a new public IP.
# ---------------------------------------------------------------------------

resource "aws_ssm_document" "deploy_frontend" {
  name            = "${var.project_name}-deploy-frontend"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Build and publish CraftCV-frontend from a develop revision"

    parameters = {
      CommitSha = {
        type           = "String"
        description    = "Full commit SHA to deploy; must be an ancestor of origin/develop"
        allowedPattern = "^[0-9a-f]{7,40}$"
      }
      AppDir = {
        type           = "String"
        description    = "Frontend checkout on the instance"
        default        = var.deploy_frontend_dir
        allowedPattern = "^/[A-Za-z0-9._/-]+$"
      }
      RepoUrl = {
        type           = "String"
        description    = "Git remote to fetch from"
        default        = "https://github.com/${var.github_owner}/${var.github_frontend_repo}.git"
        allowedPattern = "^https://github[.]com/[A-Za-z0-9._/-]+[.]git$"
      }
      WebRoot = {
        type           = "String"
        description    = "Directory nginx serves the generated site from"
        default        = var.frontend_web_root
        allowedPattern = "^/[A-Za-z0-9._/-]+$"
      }
      LockWaitSeconds = {
        type           = "String"
        description    = "How long to wait for a concurrent deploy before giving up"
        default        = "600"
        allowedPattern = "^[0-9]{1,4}$"
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "deployFrontend"
        inputs = {
          # npm ci and a Nuxt build on a 1GB instance are not quick.
          timeoutSeconds = "1800"
          runCommand     = split("\n", file("${path.module}/scripts/ssm-deploy-frontend.sh"))
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-deploy-frontend"
  }
}

# The frontend build project may now deploy - but only this document, and
# only to this instance.
resource "aws_iam_role_policy" "frontend_deploy" {
  name = "${var.project_name}-frontend-deploy-policy"
  role = aws_iam_role.frontend_ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DeployViaSsmDocument"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.craftcv_app.id}",
          aws_ssm_document.deploy_frontend.arn
        ]
      },
      {
        Sid    = "ReadSsmCommandResult"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations"
        ]
        # Command IDs are generated at call time and cannot be predicted.
        Resource = "*"
      }
    ]
  })
}
