# ---------------------------------------------------------------------------
# A stable address for the sandbox
#
# The instance stops at 18:00 and starts at 06:00, and without this it comes
# back on a different public IP every morning - breaking bookmarks, anything
# in ALLOWED_HOSTS, and any address written down anywhere.
#
# An Elastic IP also gives a permanent AWS hostname for free:
#
#     ec2-<dashed-ip>.eu-west-1.compute.amazonaws.com
#
# so there is a constant *name*, not just a constant number, without
# registering a domain or running any DNS.
#
# Cost: public IPv4 is $0.005/hour whether attached or idle, so an always
# allocated address is ~720 hours a month against the 750-hour free tier
# allowance. It is free today. If that allowance lapses it is about $3.60 a
# month, roughly $1.80 more than the current 12-hours-a-day address - still
# less than the ~$4.16 a month the stop/start schedule saves.
# ---------------------------------------------------------------------------

resource "aws_eip" "app" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-app-eip"
  }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.craftcv_app.id
  allocation_id = aws_eip.app.id
}
