# ---------------------------------------------------------------------------
# Cost guardrail
#
# This is not hypothetical. In May 2026 this account ran up $36.71 with no
# credit applied - $20 of EC2 compute and $8.81 of VPC charges - and nobody
# noticed until the bill. A budget would have said so on day three.
#
# AWS Budgets rather than a CloudWatch billing alarm on purpose: billing
# metrics only publish to us-east-1 and need "Receive Billing Alerts" turned
# on by hand in the console first, which is a silent prerequisite that is
# easy to miss. Budgets emails directly, needs no SNS topic, no subscription
# to confirm, and no second provider alias.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # include_credit = false is the important line. With credits counted, the
  # budget reads $0 for as long as they last and only starts alerting once
  # they are gone - which is the May 2026 failure exactly. Excluding them
  # makes the budget track gross consumption, so the run rate is visible
  # while there is still credit left to absorb it.
  cost_types {
    include_credit = false
    include_refund = false
    include_tax    = true
  }

  # Early warning: half the budget actually spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # The useful one: AWS projects the month will end over budget. This is what
  # catches something left running on the 3rd rather than on the 30th.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Budget actually breached.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }
}
