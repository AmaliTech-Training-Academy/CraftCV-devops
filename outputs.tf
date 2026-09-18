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
