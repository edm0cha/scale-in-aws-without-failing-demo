terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── AMI ──────────────────────────────────────────────────────────────────────

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── Networking (default VPC) ─────────────────────────────────────────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ─── Security Groups ──────────────────────────────────────────────────────────

# ALB — accepts HTTP on port 80 from the internet
resource "aws_security_group" "alb" {
  name        = "${var.app_name}-alb-sg"
  description = "Allow HTTP inbound to ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-alb-sg"
  }
}

# EC2 — accepts app traffic from the ALB and SSH from anywhere
resource "aws_security_group" "app" {
  name        = "${var.app_name}-sg"
  description = "Allow HTTP app traffic and SSH"
  vpc_id      = data.aws_vpc.default.id

  # SSH — for live debugging during the demo
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # App port — only accept traffic from the ALB
  ingress {
    description     = "App from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-sg"
  }
}

# ─── Launch Template ──────────────────────────────────────────────────────────

resource "aws_launch_template" "app" {
  name_prefix   = "${var.app_name}-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  # Enable detailed (1-minute) CloudWatch metrics so spikes show up fast
  monitoring {
    enabled = true
  }

  # Disable CPU credit throttling so utilization can reach 100 %
  credit_specification {
    cpu_credits = "unlimited"
  }

  user_data = base64encode(file("${path.module}/user-data.sh"))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = var.app_name
    }
  }
}

# ─── Auto Scaling Group ───────────────────────────────────────────────────────

resource "aws_autoscaling_group" "app" {
  name                      = "${var.app_name}-asg"
  min_size                  = 1
  max_size                  = 4
  desired_capacity          = 2
  vpc_zone_identifier       = data.aws_subnets.default.ids
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # Register instances with the ALB target group automatically
  target_group_arns = [aws_lb_target_group.app.arn]

  tag {
    key                 = "Name"
    value               = var.app_name
    propagate_at_launch = true
  }
}

# CPU-based target tracking policy — scale out when average CPU exceeds 60 %
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.app_name}-cpu-policy"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

# ─── Scheduled Scaling ────────────────────────────────────────────────────────
# All times are UTC. Adjust recurrence if your audience is in a different timezone.

# 10 PM UTC — scale fleet to 0 (night hours, no traffic expected)
# min_size must also be set to 0, otherwise the ASG will not go below its minimum
resource "aws_autoscaling_schedule" "scale_down_night" {
  scheduled_action_name  = "${var.app_name}-scale-down-night"
  autoscaling_group_name = aws_autoscaling_group.app.name
  recurrence             = "0 22 * * *"
  time_zone              = "UTC"
  min_size               = 0
  max_size               = 4
  desired_capacity       = 0
}

# 6 AM UTC — bring 1 instance back online (morning warm-up before peak traffic)
resource "aws_autoscaling_schedule" "scale_up_morning" {
  scheduled_action_name  = "${var.app_name}-scale-up-morning"
  autoscaling_group_name = aws_autoscaling_group.app.name
  recurrence             = "0 6 * * *"
  time_zone              = "UTC"
  min_size               = 1
  max_size               = 4
  desired_capacity       = 1
}

# ─── Application Load Balancer ────────────────────────────────────────────────

resource "aws_lb" "app" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name = "${var.app_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.app_name}-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.app_name}-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
