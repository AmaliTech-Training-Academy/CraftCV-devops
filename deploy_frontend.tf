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
    description   = "Publish a CraftCV-frontend build artifact from S3 to nginx"

    parameters = {
      CommitSha = {
        type           = "String"
        description    = "Commit whose build artifact to publish"
        allowedPattern = "^[0-9a-f]{7,40}$"
      }
      ArtifactBucket = {
        type           = "String"
        description    = "Bucket the build uploaded the generated site to"
        default        = aws_s3_bucket.frontend_artifacts.id
        allowedPattern = "^[a-z0-9.-]{3,63}$"
      }
      WebRoot = {
        type           = "String"
        description    = "Directory nginx serves the generated site from"
        default        = var.frontend_web_root
        allowedPattern = "^/[A-Za-z0-9._/-]+$"
      }
      AwsRegion = {
        type           = "String"
        description    = "Region the bucket lives in"
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
        name   = "deployFrontend"
        inputs = {
          # A sync of a few hundred KB, not a build.
          timeoutSeconds = "300"
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
