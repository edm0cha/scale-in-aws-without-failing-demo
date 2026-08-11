# ─── Security Groups ──────────────────────────────────────────────────────────

# ALB — accepts HTTP on port 80 from the internet
resource "aws_security_group" "alb" {
  name        = "${local.short_name}-alb-sg"
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
    Name = "${local.short_name}-alb-sg"
  }
}

# EC2 — accepts app traffic from the ALB and SSH from anywhere
resource "aws_security_group" "app" {
  name        = "${local.short_name}-sg"
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
    Name = "${local.short_name}-sg"
  }
}

# ─── IAM (instance role) ──────────────────────────────────────────────────────
# Lets the CloudWatch Agent on each instance publish memory metrics — CPU
# utilization is available for free from the hypervisor, memory is not.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.short_name}-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.short_name}-app-profile"
  role = aws_iam_role.app.name
}

# ─── Launch Template ──────────────────────────────────────────────────────────

resource "aws_launch_template" "app" {
  name_prefix   = "${local.short_name}-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

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
  name                      = "${local.short_name}-asg"
  min_size                  = 1
  max_size                  = 10
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
    value               = local.short_name
    propagate_at_launch = true
  }
}

# CPU-based target tracking policy — scale out when average CPU exceeds 60 %
# See README "Why these thresholds?" for how 60 % was derived from load-test data.
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.short_name}-cpu-policy"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 45.0
  }
}

# Memory-based target tracking policy — safety net, not the primary lever for
# this CPU-bound workload. Reads mem_used_percent published by the CloudWatch
# Agent (namespace "CWAgent", see user-data.sh) under the ASG's own dimension.
# The ASG scales to satisfy whichever of the CPU or memory policies asks for
# more capacity — they coexist, they don't override each other.
resource "aws_autoscaling_policy" "memory" {
  name                   = "${local.short_name}-memory-policy"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    customized_metric_specification {
      metric_name = "mem_used_percent"
      namespace   = "CWAgent"
      statistic   = "Average"
      unit        = "Percent"

      metric_dimension {
        name  = "AutoScalingGroupName"
        value = aws_autoscaling_group.app.name
      }
    }
    target_value = 60.0
  }
}

# ─── Scheduled Scaling ────────────────────────────────────────────────────────
# All times are UTC. Adjust recurrence if your audience is in a different timezone.

# 10 PM UTC — scale fleet to 0 (night hours, no traffic expected)
# min_size must also be set to 0, otherwise the ASG will not go below its minimum
resource "aws_autoscaling_schedule" "scale_down_night" {
  scheduled_action_name  = "${local.short_name}-scale-down-night"
  autoscaling_group_name = aws_autoscaling_group.app.name
  recurrence             = "0 22 * * *"
  time_zone              = "UTC"
  min_size               = 0
  max_size               = 4
  desired_capacity       = 0
}

# 6 AM UTC — bring 1 instance back online (morning warm-up before peak traffic)
resource "aws_autoscaling_schedule" "scale_up_morning" {
  scheduled_action_name  = "${local.short_name}-scale-up-morning"
  autoscaling_group_name = aws_autoscaling_group.app.name
  recurrence             = "0 6 * * *"
  time_zone              = "UTC"
  min_size               = 1
  max_size               = 4
  desired_capacity       = 1
}

# ─── Application Load Balancer ────────────────────────────────────────────────

resource "aws_lb" "app" {
  name               = "${local.short_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name = "${local.short_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${local.short_name}-tg"
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
    Name = "${local.short_name}-tg"
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
