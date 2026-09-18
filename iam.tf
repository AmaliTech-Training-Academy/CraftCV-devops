# IAM role: a set of permissions that AWS services can "assume".
# Here we let the EC2 SERVICE assume this role (that's what the
# assume_role_policy / "trust policy" below says), so any EC2 instance
# we attach it to inherits these permissions - no access keys needed on disk.

resource "aws_iam_role" "ec2_ssm_role" {
  name = "${var.project_name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# AWS provides a ready-made policy that grants exactly what SSM Session
# Manager needs (nothing more). This is what lets you get a shell on the
# instance without opening SSH.


resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# An "instance profile" is the wrapper that actually lets you attach an
# IAM role to an EC2 instance (you can't attach a role directly).


resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "${var.project_name}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# The deploy fetches from a private GitHub repository, so the instance needs
# to read the same token CodeBuild uses. Scoped to that one secret: the
# instance can read it and nothing else in Secrets Manager.

resource "aws_iam_role_policy" "ec2_read_github_token" {
  name = "${var.project_name}-ec2-read-github-token"
  role = aws_iam_role.ec2_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
