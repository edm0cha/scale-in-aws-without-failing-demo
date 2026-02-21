output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "instance_type" {
  description = "EC2 instance type used by the launch template"
  value       = var.instance_type
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
