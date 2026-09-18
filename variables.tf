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

# --- Deployment (Phase 6) -------------------------------------------------

# Note the name: this directory holds the *application* checkout, despite
# being called CraftCV-devops. It was cloned under the wrong name before this
# phase and is left alone rather than renamed, because the running compose
# stack refers to it. Worth correcting the next time the box is rebuilt.
variable "deploy_app_dir" {
  description = "Directory on the instance that docker compose runs from"
  type        = string
  default     = "/opt/craftcv/CraftCV-devops"
}

# --- Sandbox schedule -----------------------------------------------------

variable "sandbox_schedule_enabled" {
  description = "Whether the start/stop schedules are active"
  type        = bool
  default     = true
}

variable "sandbox_start_hour" {
  description = "Hour of day the sandbox starts, 0-23, in sandbox_schedule_timezone"
  type        = number
  default     = 6

  validation {
    condition     = var.sandbox_start_hour >= 0 && var.sandbox_start_hour <= 23
    error_message = "sandbox_start_hour must be an hour between 0 and 23."
  }
}

variable "sandbox_stop_hour" {
  description = "Hour of day the sandbox stops, 0-23, in sandbox_schedule_timezone"
  type        = number
  default     = 18

  validation {
    condition     = var.sandbox_stop_hour >= 0 && var.sandbox_stop_hour <= 23
    error_message = "sandbox_stop_hour must be an hour between 0 and 23."
  }
}

# Africa/Accra, not the eu-west-1 region's local time. The people using this
# sandbox are in Ghana, and Accra has no daylight saving, so 06:00 stays 06:00
# all year. Set this to Europe/Dublin if the schedule should instead follow
# the region, and accept that the wall-clock time then shifts twice a year.
variable "sandbox_schedule_timezone" {
  description = "IANA timezone the start/stop hours are interpreted in"
  type        = string
  default     = "Africa/Accra"
}

# Every day by default. Set to "MON-FRI" to leave it off at weekends, which
# roughly doubles the saving if nobody works then.
variable "sandbox_schedule_days" {
  description = "Cron day-of-week field: * for daily, MON-FRI for weekdays"
  type        = string
  default     = "*"
}
