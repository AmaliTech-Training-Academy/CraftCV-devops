# ---------------------------------------------------------------------------
# Frontend artifact bucket
#
# CodeBuild already generates the site while running the build gate. Rather
# than repeat that work on the instance, it uploads the result here and the
# instance syncs it down.
#
# This is not "hosting the frontend on S3". The bucket is private and nginx
# still serves the files from the instance, so the app and the API keep a
# single origin: no CORS between them, and no server address baked into the
# bundle to go stale when the sandbox restarts on a new IP.
#
# What it buys is size. Building on the box cost 364MB of node_modules, an
# 84MB npm cache and a 137MB Node runtime to serve 220KB of output. Syncing
# from S3 costs the 220KB.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "frontend_artifacts" {
  bucket = "${var.project_name}-frontend-artifacts-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}-frontend-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend_artifacts" {
  bucket = aws_s3_bucket.frontend_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend_artifacts" {
  bucket = aws_s3_bucket.frontend_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Each build writes under its own commit prefix, so old ones pile up. Thirty
# days is long enough to roll back to something anyone still remembers.
resource "aws_s3_bucket_lifecycle_configuration" "frontend_artifacts" {
  bucket = aws_s3_bucket.frontend_artifacts.id

  rule {
    id     = "expire-old-builds"
    status = "Enabled"

    filter {
      prefix = "builds/"
    }

    expiration {
      days = 30
    }
  }
}

# Refuse anything not over TLS.
resource "aws_s3_bucket_policy" "frontend_artifacts" {
  bucket = aws_s3_bucket.frontend_artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.frontend_artifacts.arn,
          "${aws_s3_bucket.frontend_artifacts.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend_artifacts]
}

# --- Who may write, who may read -------------------------------------------

# The build uploads; it cannot read anything back or delete history.
resource "aws_iam_role_policy" "frontend_ci_artifacts" {
  name = "${var.project_name}-frontend-ci-artifacts"
  role = aws_iam_role.frontend_ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UploadBuilds"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.frontend_artifacts.arn}/builds/*"
      },
      {
        Sid      = "ListForSync"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend_artifacts.arn
      }
    ]
  })
}

# The instance reads; it cannot write.
resource "aws_iam_role_policy" "ec2_read_frontend_artifacts" {
  name = "${var.project_name}-ec2-read-frontend-artifacts"
  role = aws_iam_role.ec2_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DownloadBuilds"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.frontend_artifacts.arn}/builds/*"
      },
      {
        Sid      = "ListForSync"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend_artifacts.arn
      }
    ]
  })
}
