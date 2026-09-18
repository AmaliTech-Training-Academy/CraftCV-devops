# A security group is a virtual firewall attached to the EC2 instance.
# "ingress" = inbound traffic rules. "egress" = outbound traffic rules.
#
# Notice what's NOT here: port 22 (SSH) and port 5432 (PostgreSQL) are
# never opened to the internet. Administration happens via SSM instead,
# and Postgres only needs to be reachable from Django, not the outside world.

resource "aws_security_group" "craftcv_app" {
  name        = "${var.project_name}-app-sg"
  description = "Allow inbound HTTP/HTTPS only; no SSH, no DB"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere (for later, once you add TLS)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound traffic is left open so the instance can reach the internet
  # (e.g. to pull Docker images, apt packages, or talk to SSM).
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}
