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

variable "github_branch" {
  description = "Branch CI treats as the mainline (pushes and PR targets)"
  type        = string
  default     = "main"
}

# Terraform can create a CodeConnections connection but cannot complete the
# GitHub App handshake - that is a one-time click in the AWS console. Until
# it is done, AWS rejects the source-credential and webhook API calls, so
# they are created on a second apply with this set to true. See README.
variable "github_connection_authorized" {
  description = "Set true once the CodeConnections GitHub connection is AVAILABLE"
  type        = bool
  default     = false
}

variable "coverage_min" {
  description = "Minimum test coverage percentage; the build fails below this"
  type        = number
  default     = 80

  validation {
    condition     = var.coverage_min >= 0 && var.coverage_min <= 100
    error_message = "coverage_min must be a percentage between 0 and 100."
  }
}
