# Variables let you avoid hardcoding values inside every resource block.
# You can override these at apply time with -var, a .tfvars file, or
# (as done here) just change the default.

variable "vpc_id" {
  description = "The default VPC to deploy into"
  type        = string
  default     = "vpc-0f179893ebd2af926"
}

variable "subnet_id" {
  description = "The subnet the EC2 instance will live in (must be public for now)"
  type        = string
  default     = "subnet-01871ad2f9342e2ff"
}

variable "project_name" {
  description = "Used to name/tag resources consistently"
  type        = string
  default     = "craftcv"
}

# --- CI (Phase 5) ---------------------------------------------------------

variable "github_owner" {
  description = "GitHub organization that owns the application repository"
  type        = string
  default     = "AmaliTech-Training-Academy"
}

variable "github_repo" {
  description = "Application repository CodeBuild builds from"
  type        = string
  default     = "CraftCV-backend"
}

# CraftCV-backend integrates into develop, not main - that is its default
# branch and what a manual build checks out.
variable "github_default_branch" {
  description = "Repository default branch; what a manual build checks out"
  type        = string
  default     = "develop"
}

# Matches the Actions workflow, which runs on pushes to main and develop and
# on every pull request.
variable "github_ci_branches" {
  description = "Branches whose pushes, and PR targets, trigger a build"
  type        = list(string)
  default     = ["develop", "main"]

  validation {
    condition     = length(var.github_ci_branches) > 0
    error_message = "At least one branch must trigger CI."
  }
}

# The secret holding the GitHub personal access token CodeBuild authenticates
# with. It is created out of band (see README) so the token never passes
# through Terraform, and only its ARN is referenced.
variable "github_token_secret_name" {
  description = "Secrets Manager secret holding the GitHub PAT for CodeBuild"
  type        = string
  default     = "craftcv/github-token"
}

# No coverage_min variable: CraftCV-backend's gate is `manage.py test`, which
# enforces no coverage threshold. Add one here only if the suite moves to a
# runner that measures coverage.
