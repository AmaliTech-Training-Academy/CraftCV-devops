# ECR (Elastic Container Registry) is the private Docker registry that CI
# pushes to. The build in CodeBuild produces an image; the deploy step (next
# phase) pulls that same image onto the EC2 instance. Without a registry in
# between, "docker build" in CI would be throwaway work.

resource "aws_ecr_repository" "app" {
  name = "${var.project_name}-backend"

  # Tags are immutable so a given tag always means one exact image. This is
  # what lets us deploy by commit SHA and know precisely what is running.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Free, automatic CVE scan on every push. Findings show up in ECR.
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-backend"
  }
}

# Untagged layers accumulate every time a build is superseded. This keeps the
# repository from growing without bound (and keeps storage cost near zero).

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep only the 30 most recent tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
