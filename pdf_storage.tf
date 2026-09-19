# ---------------------------------------------------------------------------
# Generated CV PDFs
#
# The PDF is rendered on the instance and the finished file is put here, so
# that:
#
#   - a repeat download of an unchanged CV is an S3 read, not a re-render.
#     Most of the load in a demo is the same file being fetched again;
#   - the download goes browser -> S3 through a presigned URL, so gunicorn is
#     not tied up streaming bytes on a 1 GiB box.
#
# What this does NOT do is make the render cheaper. The memory cost is in
# whatever lays the CV out, not in the finished file - a CV PDF is a few
# hundred KB, a headless browser is a few hundred MB. That is an argument for
# rendering with WeasyPrint rather than a browser, not an argument about
# storage.
#
# Deliberately unlike the backup bucket: no versioning. These objects are
# regenerable from the database at any time, so a superseded PDF is worth
# nothing and paying to keep old versions of it would be silly.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "cv_pdfs" {
  bucket = "${var.project_name}-cv-pdfs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.project_name}-cv-pdfs"
    ProjectEnds = var.project_end_date
  }
}

resource "aws_s3_bucket_public_access_block" "cv_pdfs" {
  bucket                  = aws_s3_bucket.cv_pdfs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cv_pdfs" {
  bucket = aws_s3_bucket.cv_pdfs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# These files are somebody's name, address, phone number and employment
# history. They are a cache, not a record - the database is the record - so
# they expire quickly and the bucket does not become a pile of personal data
# nobody remembers is there.
resource "aws_s3_bucket_lifecycle_configuration" "cv_pdfs" {
  bucket = aws_s3_bucket.cv_pdfs.id

  rule {
    id     = "expire-generated-pdfs"
    status = "Enabled"

    filter {
      prefix = "cvs/"
    }

    expiration {
      days = var.pdf_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "cv_pdfs" {
  bucket = aws_s3_bucket.cv_pdfs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.cv_pdfs.arn, "${aws_s3_bucket.cv_pdfs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cv_pdfs]
}

# A presigned URL followed by a plain navigation needs no CORS at all. This
# exists for the case where the frontend fetches the URL with XHR to drive its
# own "Downloading..." state, which is the more likely implementation. The
# objects stay private either way: without a signature there is nothing to
# read, whatever origin asks.
resource "aws_s3_bucket_cors_configuration" "cv_pdfs" {
  bucket = aws_s3_bucket.cv_pdfs.id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    expose_headers  = ["Content-Disposition", "Content-Length"]
    max_age_seconds = 3600
  }
}

# The instance writes rendered PDFs, reads them back on a cache hit, and
# deletes the stale one when a CV is edited. Scoped to the cvs/ prefix.
#
# Note for whoever writes the signing code: these are instance-role
# credentials, which are temporary. A presigned URL made with them dies when
# the underlying session token expires, whatever expiry was asked for. Keep
# the expiry short - minutes - and that is never a problem.
resource "aws_iam_role_policy" "ec2_cv_pdfs" {
  name = "${var.project_name}-ec2-cv-pdfs"
  role = aws_iam_role.ec2_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWriteGeneratedPdfs"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.cv_pdfs.arn}/cvs/*"
      }
    ]
  })
}
