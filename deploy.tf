# ---------------------------------------------------------------------------
# Phase 6: Continuous deployment over SSM
#
#   green build on develop -> CodeBuild calls ssm:SendCommand
#       -> craftcv-deploy document runs on the app instance
#           -> fetch/reset to the commit -> compose build -> migrate
#              -> recreate web -> health check
#
# No SSH, no key pair, port 22 stays closed. The deploy is a *document*
# rather than a script sitting on the box so that what runs is version
# controlled here, and so the CodeBuild role can be allowed to run exactly
# this one thing and nothing else.
# ---------------------------------------------------------------------------

resource "aws_ssm_document" "deploy" {
  name            = "${var.project_name}-deploy"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy CraftCV-backend to the app instance from a develop revision"

    parameters = {
      CommitSha = {
        type        = "String"
        description = "Full commit SHA to deploy; must be an ancestor of origin/develop"
        # Constrains the input before it ever reaches the shell.
        allowedPattern = "^[0-9a-f]{7,40}$"
      }
      AppDir = {
        type        = "String"
        description = "Checkout on the instance that compose runs from"
        default     = var.deploy_app_dir
        # No spaces, quotes or shell metacharacters.
        allowedPattern = "^/[A-Za-z0-9._/-]+$"
      }
      RepoUrl = {
        type           = "String"
        description    = "Git remote to fetch from"
        default        = "https://github.com/${var.github_owner}/${var.github_repo}.git"
        allowedPattern = "^https://github[.]com/[A-Za-z0-9._/-]+[.]git$"
      }
      TokenSecretId = {
        type           = "String"
        description    = "Secrets Manager secret holding the GitHub token"
        default        = var.github_token_secret_name
        allowedPattern = "^[A-Za-z0-9/_+=.@-]+$"
      }
      AwsRegion = {
        type           = "String"
        description    = "Region to read the secret from"
        default        = "eu-west-1"
        allowedPattern = "^[a-z0-9-]+$"
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
        name   = "deploy"
        inputs = {
          timeoutSeconds = "900"
          # Kept in its own file so it can be read, diffed and shell-linted
          # rather than buried as a string inside HCL.
          runCommand = split("\n", file("${path.module}/scripts/ssm-deploy.sh"))
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-deploy"
  }
}
