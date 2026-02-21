output "instance_id" {
  description = "EC2 instance 1 ID"
  value       = aws_instance.app.id
}

output "instance_id_2" {
  description = "EC2 instance 2 ID"
  value       = aws_instance.app2.id
}

output "public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.app.public_ip
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.app.dns_name
}

output "app_url" {
  description = "Base URL of the demo app (via ALB)"
  value       = "http://${aws_lb.app.dns_name}"
}

output "health_url" {
  description = "Health-check endpoint (via ALB)"
  value       = "http://${aws_lb.app.dns_name}/health"
}

output "work_url" {
  description = "CPU-intensive endpoint (via ALB)"
  value       = "http://${aws_lb.app.dns_name}/work"
}
