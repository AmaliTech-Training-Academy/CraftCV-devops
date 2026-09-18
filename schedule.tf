# ---------------------------------------------------------------------------
# Sandbox start/stop schedule
#
# The app server is a sandbox. Running it overnight and at weekends costs
# money for nothing, so EventBridge Scheduler starts it in the morning and
# stops it in the evening.
#
# Deliberately the smallest thing that works: two schedules and one role.
# No Lambda to write and patch, no Instance Scheduler solution stack, no
# extra service to understand. EventBridge Scheduler calls the EC2 API
# directly through a universal target.
# ---------------------------------------------------------------------------

# Trust policy restricted to this account, so the role cannot be used by a
# schedule in someone else's account that happens to know its ARN.
resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-scheduler-role"
  }
}

# Start and stop, on one instance. Not ec2:* and not "*" - this role can
# power-cycle the sandbox and do nothing else.
resource "aws_iam_role_policy" "scheduler" {
  name = "${var.project_name}-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StartStopSandbox"
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances"
        ]
        Resource = "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.craftcv_app.id}"
      }
    ]
  })
}

resource "aws_scheduler_schedule" "sandbox_start" {
  name        = "${var.project_name}-sandbox-start"
  description = "Start the sandbox app server at ${var.sandbox_start_hour}:00 ${var.sandbox_schedule_timezone}"
  state       = var.sandbox_schedule_enabled ? "ENABLED" : "DISABLED"
  group_name  = "default"

  # OFF means run at the stated time, not somewhere inside a window.
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 ${var.sandbox_start_hour} ? * ${var.sandbox_start_days} *)"
  schedule_expression_timezone = var.sandbox_schedule_timezone

  target {
    # Universal target: EventBridge Scheduler calls the EC2 API itself, so
    # there is no function in between to maintain.
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.craftcv_app.id]
    })

    retry_policy {
      maximum_retry_attempts = 3
    }
  }
}

resource "aws_scheduler_schedule" "sandbox_stop" {
  name        = "${var.project_name}-sandbox-stop"
  description = "Stop the sandbox app server at ${var.sandbox_stop_hour}:00 ${var.sandbox_schedule_timezone}"
  state       = var.sandbox_schedule_enabled ? "ENABLED" : "DISABLED"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 ${var.sandbox_stop_hour} ? * ${var.sandbox_stop_days} *)"
  schedule_expression_timezone = var.sandbox_schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.craftcv_app.id]
    })

    retry_policy {
      maximum_retry_attempts = 3
    }
  }
}
