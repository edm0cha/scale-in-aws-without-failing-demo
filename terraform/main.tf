resource "aws_security_group" "app" {
  name        = "${local.short_name}-sg"
  description = "Allow HTTP app traffic and SSH"

  # SSH — for live debugging during the demo
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # App port — the Node.js server
  ingress {
    description = "App"
    from_port   = 3000
    to_port     = 3000
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
    Name = "${local.short_name}-sg"
  }
}

# ─── EC2 Instance ─────────────────────────────────────────────────────────────

resource "aws_instance" "app" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true

  # Enable detailed (1-minute) CloudWatch metrics so spikes show up fast
  monitoring = true

  user_data                   = file("${path.module}/user-data.sh")
  user_data_replace_on_change = true

  # Disable CPU credit throttling so utilization can reach 100 %
  # Only applies to T2/T3/T4g burstable instance families
  credit_specification {
    cpu_credits = "unlimited"
  }

  tags = {
    Name = local.short_name
  }
}
