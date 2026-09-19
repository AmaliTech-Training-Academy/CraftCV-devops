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
variable "github_frontend_repo" {
  description = "Frontend repository CodeBuild runs quality gates on"
  type        = string
  default     = "CraftCV-frontend"
}

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

variable "deploy_frontend_dir" {
  description = "Frontend checkout on the instance"
  type        = string
  default     = "/opt/craftcv/CraftCV-frontend"
}

variable "frontend_web_root" {
  description = "Directory nginx serves the generated frontend from"
  type        = string
  default     = "/var/www/craftcv"
}

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

# Weekdays only. Nobody is working at the weekend, so there is no reason to
# pay for 24 hours of instance across Saturday and Sunday.
variable "sandbox_start_days" {
  description = "Cron day-of-week the sandbox is started on"
  type        = string
  default     = "MON-FRI"
}

# Stop runs EVERY day, deliberately not MON-FRI. If the stop were also
# weekday-only, an instance started by hand on a Saturday would keep running
# until Monday evening - the exact runaway this schedule exists to prevent.
# A stop with nothing to stop is free and harmless.
variable "sandbox_stop_days" {
  description = "Cron day-of-week the sandbox is stopped on"
  type        = string
  default     = "*"
}

# --- Cost guardrail -------------------------------------------------------

# Deliberately tight. A quiet month here is well under a dollar, and the
# stop/start schedule is meant to keep it that way, so $5 is already an
# anomaly worth an email. May 2026 reached $36.71 uncredited - that would
# now trip the forecast alert within the first few days rather than at the
# end of the month.
variable "monthly_budget_usd" {
  description = "Monthly spend that triggers the budget alerts"
  type        = number
  default     = 5

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "budget_alert_emails" {
  description = "Addresses the budget notifications are sent to"
  type        = list(string)
  default     = ["ishaque.appiah@amalitech.com"]

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "At least one address must receive budget alerts."
  }
}

# --- Backups and project lifetime -----------------------------------------

# 17:45, fifteen minutes before the 18:00 stop. Close enough that the dump
# reflects a full day's work, far enough that a slow dump is not cut off
# mid-write by the instance shutting down.
variable "backup_hour" {
  description = "Hour the nightly database dump runs, in sandbox_schedule_timezone"
  type        = number
  default     = 17
}

variable "backup_minute" {
  description = "Minute the nightly database dump runs"
  type        = number
  default     = 45
}

# Two weeks is enough: dumps are a safety net for work happening now, not an
# archive. Nobody restoring this sandbox wants a three-week-old database.
#
# The ceiling is 42 days, the length of the project, and that is the point of
# the validation: a retention longer than the project would leave data
# sitting in S3 after the account has been handed back.
variable "backup_retention_days" {
  description = "Days a database dump is kept before S3 expires it; must not outlive the project"
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 42
    error_message = "backup_retention_days must be between 1 and 42 - the project runs six weeks and backups must not outlive it."
  }
}

# Recorded as a tag on the resources that cost money, so anyone auditing the
# account later can see what should already be gone. This is documentation,
# not automation: nothing destroys itself on this date.
variable "project_end_date" {
  description = "Date the sandbox is expected to be torn down (YYYY-MM-DD)"
  type        = string
  default     = "2026-10-30"

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.project_end_date))
    error_message = "project_end_date must be YYYY-MM-DD."
  }
}

# PDFs are a cache of something the database can regenerate, and they hold
# personal details, so they do not linger. A week covers "I downloaded this
# on Monday and want it again on Friday" and nothing beyond that.
variable "pdf_retention_days" {
  description = "Days a generated CV PDF is kept in S3 before it expires"
  type        = number
  default     = 7

  validation {
    condition     = var.pdf_retention_days >= 1 && var.pdf_retention_days <= 42
    error_message = "pdf_retention_days must be between 1 and 42 - the project runs six weeks and nothing here should outlive it."
  }
}
