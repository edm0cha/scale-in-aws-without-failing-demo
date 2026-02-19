output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.app.public_ip
}

output "app_url" {
  description = "Base URL of the demo app"
  value       = "http://${aws_instance.app.public_ip}:3000"
}

output "health_url" {
  description = "Health-check endpoint"
  value       = "http://${aws_instance.app.public_ip}:3000/health"
}

output "work_url" {
  description = "CPU-intensive endpoint (target for load test)"
  value       = "http://${aws_instance.app.public_ip}:3000/work"
}
