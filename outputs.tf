# "outputs" print useful values to your terminal after `terraform apply`,
# and let you fetch them later with `terraform output <name>`.

output "instance_id" {
  description = "EC2 instance ID - you'll use this with SSM"
  value       = aws_instance.craftcv_app.id
}

output "instance_public_ip" {
  description = "Public IP - use this to test HTTP access later"
  value       = aws_instance.craftcv_app.public_ip
}

output "security_group_id" {
  description = "Security group ID attached to the instance"
  value       = aws_security_group.craftcv_app.id
}

# --- CI (Phase 5) ---------------------------------------------------------

output "codebuild_project_name" {
  description = "Use with: aws codebuild start-build --project-name <this>"
  value       = aws_codebuild_project.backend_ci.name
}

output "codebuild_role_arn" {
  description = "Service role the build (and later the deploy) runs as"
  value       = aws_iam_role.codebuild.arn
}

output "github_token_secret_arn" {
  description = "Secret CodeBuild reads the GitHub token from"
  value       = data.aws_secretsmanager_secret.github_token.arn
}

output "webhook_payload_url" {
  description = "Endpoint CodeBuild registered on the GitHub repository"
  value       = aws_codebuild_webhook.backend_ci.payload_url
}

output "ecr_repository_url" {
  description = "Image repository CI pushes to; the deploy step pulls from here"
  value       = aws_ecr_repository.app.repository_url
}
