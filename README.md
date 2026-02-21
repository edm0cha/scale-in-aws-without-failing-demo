# Does my application need balancing? — Right-Sizing

> **Branch:** `04-right-sizing`
>
> The same ASG + ALB infrastructure from `03-auto-scaling-group`, but with a **compute-optimized
> instance type** (`c5.large`) instead of `t2.micro`.
> We'll show that scaling out is not always the answer — choosing the right instance family
> for your workload reduces instance count, eliminates throttling, and improves reliability.

---

## What's in this branch

| Path | Purpose |
|------|---------|
| `terraform/` | Same ASG + ALB infrastructure — only `instance_type` changes |
| `app/` | Node.js app source (unchanged — same CPU-bound workload) |
| `load-test/artillery.yml` | Same load test as `03` — identical traffic for a fair comparison |

### The workload profile

The `/work` endpoint runs a **synchronous prime sieve** — purely CPU-bound, no I/O, no memory pressure.

| Workload type | Right instance family | Wrong instance family |
|--------------|----------------------|-----------------------|
| CPU-bound | `c` (compute-optimized) | `t` (burstable) |
| Memory-bound | `r` (memory-optimized) | `t`, `c` |
| I/O / network | `i` (storage), `c` | `t`, `r` |

This app is CPU-bound → `c5.large` is the right fit.

### Why `t2.micro` was wrong

| Property | `t2.micro` | `c5.large` |
|----------|-----------|-----------|
| vCPU | 1 | 2 |
| RAM | 1 GB | 4 GB |
| CPU model | Shared, burstable | Dedicated, compute-optimized |
| Throttling | Yes — hard cap at 10 % when credits run out | No — full 100 % always available |
| Price (us-east-1) | $0.012/hr | $0.085/hr |
| Reliable req/s | ~15 | ~70+ |
| Cost per reliable req/s | ~$0.0008 | ~$0.0012 |

`t2.micro` looks cheaper per hour, but once it exhausts its CPU credits it throttles to 10 % — the
instance is still running and still billing, but effectively useless. `c5.large` delivers consistent
performance with no surprises.

### The infrastructure

Identical to `03-auto-scaling-group`:

```
Internet
    │
    ▼
Application Load Balancer  (port 80)
    │
    └──▶ Auto Scaling Group (min 1 / desired 2 / max 4)
              ├── c5.large instance 1  (port 3000)
              └── c5.large instance 2  (port 3000)
```

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6
- [Artillery](https://www.artillery.io/docs/get-started/get-artillery) (`npm install -g artillery`)
- AWS credentials configured (`aws configure` or env vars)

---

## Live demo walkthrough

### 1 — Show the only change: `variables.tf`

Open `terraform/variables.tf` and point out the default:

```hcl
variable "instance_type" {
  default = "c5.large"   # was "t2.micro" in previous branches
}
```

**Talking point:** one line changed. Same app, same infrastructure, same load test. Only the instance
family changed — from general-purpose burstable to compute-optimized.

### 2 — Deploy

```bash
cd terraform
terraform init
terraform apply
```

Outputs:

```
asg_name      = "scale-demo-asg"
instance_type = "c5.large"
app_url       = "http://scale-demo-alb-1234567890.us-east-1.elb.amazonaws.com"
```

### 3 — Wait for the initial instances to start (~90 s)

```bash
curl $(terraform output -raw health_url)
# {"status":"ok","instance":"i-0abc..."}
```

### 4 — Open CloudWatch — compare both branches side by side

Open two browser tabs:
- `03-auto-scaling-group` CloudWatch graph (screenshot or live if still running)
- `04-right-sizing` CloudWatch graph (live)

Metrics to watch:
- **CPUUtilization per instance** — should stay lower per instance on `c5.large`
- **Group In Service Instances** — should plateau at 2 instead of climbing to 4
- **Group Desired Capacity** — minimal scaling activity expected

### 5 — Run the same load test

```bash
cd ../load-test
export TARGET_URL=$(cd ../terraform && terraform output -raw app_url)
artillery run artillery.yml

# Save results to JSON for later analysis
artillery run artillery.yml --output report.json

# Generate an HTML report from the JSON output
artillery report report.json
```

Same three phases as `03`:

| Phase | Duration | Rate |
|-------|----------|------|
| Warm up | 30 s | 5 req/s |
| Ramp up | 60 s | 5 → 70 req/s |
| Sustained | 240 s | 70 req/s |

**What to show the audience:**

1. During *Warm up* — identical to `03`. No surprises at low load.
2. During *Ramp up* — CPU climbs, but each `c5.large` handles more req/s before hitting 60 %. The ASG fires later (or not at all) compared to `t2.micro`.
3. During *Sustained* — compare the Artillery report to `03`:

| Metric | `t2.micro` (branch 03) | `c5.large` (branch 04) |
|--------|----------------------|----------------------|
| Instances at peak | 3–4 | 1–2 |
| `ETIMEDOUT` errors | Many | Few or none |
| p99 latency | ~9 s | < 1 s |
| ASG scale-out events | Multiple | 0–1 |

### 6 — Show how to switch instance types without changing anything else

The instance type is the only variable. You can override it at apply time:

```bash
# Try a memory-optimized instance (not ideal for this workload — for illustration)
terraform apply -var="instance_type=r6i.large"

# Try a newer-gen compute-optimized instance
terraform apply -var="instance_type=c6i.large"
```

### 7 — Clean up

```bash
cd ../terraform
terraform destroy
```

---

## Key takeaway for the talk

> Before you scale out, ask: **is this the right instance type for my workload?**
>
> A CPU-bound app on a burstable `t2` instance will throttle under load no matter how many instances
> you add. One correctly-sized `c5.large` outperforms four throttled `t2.micro` instances — with
> fewer moving parts, simpler operations, and more predictable costs.
>
> Right-sizing is not about spending more. It's about spending on the right thing.

---

## Branch roadmap

| Branch | What it adds |
|--------|--------------|
| `main` | Single EC2, no load balancer |
| `01-implement-alb` | ALB in front of two fixed EC2s |
| `02-saturate-alb` | Push the fixed fleet past its ceiling |
| `03-auto-scaling-group` | ASG with CPU-based scaling policy |
| `04-right-sizing` | ← you are here — compute-optimized instance type |
