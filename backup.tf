# ---------------------------------------------------------------------------
# Database backups
#
# The database lives in a Docker volume on the instance's EBS root volume.
# That survives the nightly stop/start, but the root volume has
# DeleteOnTermination = true, so terminating the instance - including via
# terraform destroy - takes the data with it. These dumps are the only thing
# that makes that recoverable.
#
# The dump runs shortly before the scheduled stop rather than at midnight,
# because at midnight the instance is off.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "backups" {
  bucket = "${var.project_name}-db-backups-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.project_name}-db-backups"
    ProjectEnds = var.project_end_date
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning so an overwritten latest.dump is still recoverable.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Dumps expire on their own. The project runs six weeks; nothing here needs
# to outlive it, and an expiry means the bucket cannot quietly accumulate
# cost after everyone has moved on.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-dumps"
    status = "Enabled"

    filter {
      prefix = "db/"
    }

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# The instance writes dumps and reads them back to restore.
resource "aws_iam_role_policy" "ec2_backups" {
  name = "${var.project_name}-ec2-db-backups"
  role = aws_iam_role.ec2_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteAndReadDumps"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.backups.arn}/db/*"
      },
      {
        Sid      = "ListForRestore"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.backups.arn
      }
    ]
  })
}

# --- Documents -------------------------------------------------------------

resource "aws_ssm_document" "db_backup" {
  name            = "${var.project_name}-db-backup"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Dump the CraftCV database to S3"

    parameters = {
      AppDir = {
        type           = "String"
        default        = var.deploy_app_dir
        description    = "Checkout that docker compose runs from"
        allowedPattern = "^/[A-Za-z0-9._/-]+$"
      }
      BackupBucket = {
        type           = "String"
        default        = aws_s3_bucket.backups.id
        description    = "Bucket the dump is written to"
        allowedPattern = "^[a-z0-9.-]{3,63}$"
      }
      AwsRegion = {
        type           = "String"
        default        = data.aws_region.current.name
        description    = "Region the bucket lives in"
        allowedPattern = "^[a-z0-9-]+$"
      }
    }

    mainSteps = [{
      action = "aws:runShellScript"
      name   = "backup"
      inputs = {
        timeoutSeconds = "600"
        runCommand     = split("\n", file("${path.module}/scripts/ssm-db-backup.sh"))
      }
    }]
  })

  tags = { Name = "${var.project_name}-db-backup" }
}

resource "aws_ssm_document" "db_restore" {
  name            = "${var.project_name}-db-restore"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Restore the CraftCV database from a dump in S3 (destructive)"

    parameters = {
      AppDir = {
        type           = "String"
        default        = var.deploy_app_dir
        description    = "Checkout that docker compose runs from"
        allowedPattern = "^/[A-Za-z0-9._/-]+$"
      }
      BackupBucket = {
        type           = "String"
        default        = aws_s3_bucket.backups.id
        description    = "Bucket to read the dump from"
        allowedPattern = "^[a-z0-9.-]{3,63}$"
      }
      Key = {
        type           = "String"
        default        = "db/latest.dump"
        description    = "Object key of the dump to restore"
        allowedPattern = "^db/[A-Za-z0-9._-]+$"
      }
      AwsRegion = {
        type           = "String"
        default        = data.aws_region.current.name
        description    = "Region the bucket lives in"
        allowedPattern = "^[a-z0-9-]+$"
      }
      Confirm = {
        type           = "String"
        default        = "NO"
        description    = "Must be the word RESTORE. A restore drops existing data."
        allowedPattern = "^[A-Z]+$"
      }
    }

    mainSteps = [{
      action = "aws:runShellScript"
      name   = "restore"
      inputs = {
        timeoutSeconds = "900"
        runCommand     = split("\n", file("${path.module}/scripts/ssm-db-restore.sh"))
      }
    }]
  })

  tags = { Name = "${var.project_name}-db-restore" }
}

# --- Schedule --------------------------------------------------------------

# Runs before the 18:00 stop, not after. The gap is deliberate: if the dump
# overran into the stop, the instance would be halted mid-backup.
resource "aws_scheduler_schedule" "db_backup" {
  name        = "${var.project_name}-db-backup"
  description = "Dump the database to S3 before the sandbox stops for the night"
  state       = var.sandbox_schedule_enabled ? "ENABLED" : "DISABLED"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(${var.backup_minute} ${var.backup_hour} ? * ${var.sandbox_start_days} *)"
  schedule_expression_timezone = var.sandbox_schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ssm:sendCommand"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      DocumentName = aws_ssm_document.db_backup.name
      InstanceIds  = [aws_instance.craftcv_app.id]
      Comment      = "scheduled nightly backup"
    })

    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}

# The scheduler role can start and stop the instance; it now also needs to
# run this one document on it.
resource "aws_iam_role_policy" "scheduler_backup" {
  name = "${var.project_name}-scheduler-backup"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunBackupDocument"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.craftcv_app.id}",
          aws_ssm_document.db_backup.arn
        ]
      }
    ]
  })
}
