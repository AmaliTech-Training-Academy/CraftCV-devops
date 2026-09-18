# A "data" block doesn't create anything - it looks up existing information.
# Here, we ask AWS for the latest official Ubuntu 22.04 image ID, so we
# don't have to hardcode an AMI ID that will go stale over time.


data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "craftcv_app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro" # small/cheap - fine for a sandbox
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.craftcv_app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm_profile.name

  # Needed so you can actually reach it over the internet on port 80.
  # Only safe because the security group above restricts what's allowed in.
  associate_public_ip_address = true

  tags = {
    Name = "${var.project_name}-app-server"
  }
}
