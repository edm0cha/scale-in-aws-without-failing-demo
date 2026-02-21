variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type for the ASG launch template.

    Choose based on your workload profile:

    CPU-bound (this demo — prime sieve, encoding, ML inference):
      c5.large    — compute-optimized, 2 vCPU, 4 GB,  $0.085/hr  ← default
      c6i.large   — latest-gen compute, 2 vCPU, 4 GB,  $0.085/hr
      c5.xlarge   — 4 vCPU, 8 GB,  $0.170/hr

    Memory-bound (large caches, in-memory DBs, JVM apps):
      r6i.large   — memory-optimized, 2 vCPU, 16 GB, $0.126/hr
      r6i.xlarge  — 4 vCPU, 32 GB, $0.252/hr

    Burstable general-purpose (dev/test, low-traffic APIs):
      t3.micro    — 2 vCPU, 1 GB,  $0.010/hr  (unlimited burst)
      t3.small    — 2 vCPU, 2 GB,  $0.021/hr
      t2.micro    — 1 vCPU, 1 GB,  $0.012/hr  (credit throttling — avoid for prod)
  EOT
  type        = string
  default     = "c5.large"
}

variable "app_name" {
  description = "Name tag applied to all resources"
  type        = string
  default     = "scale-demo"
}
