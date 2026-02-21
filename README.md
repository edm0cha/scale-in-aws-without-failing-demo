# Does my application need balancing? — Auto Scaling Group

> **Branch:** `03-auto-scaling-group`
>
> An Application Load Balancer fronting an **Auto Scaling Group** of `t2.micro` instances.
> When CPU exceeds 60 %, AWS automatically launches new instances and registers them with the ALB.
> When load drops, it terminates the extras. No manual intervention required.

---

## What's in this branch

| Path | Purpose |
|------|---------|
| `terraform/` | Infrastructure — ASG + Launch Template + ALB + Security Groups in us-east-1 |
| `app/` | Node.js app source (also embedded in `user-data.sh`) |
| `load-test/artillery.yml` | Artillery scenario that triggers and observes the ASG scale-out |

### The app

Two endpoints:

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Liveness check — returns `200` and the responding `instance` ID |
| `GET /work` | **Synchronous** prime-number calculation. Blocks the event loop. On a `t2.micro`, each request takes ~300–600 ms. Under concurrent load, CPU climbs and the ASG reacts. |

### The infrastructure

```
Internet
    │
    ▼
Application Load Balancer  (port 80)
    │
    ├──▶ EC2 instance 1  (port 3000)  ─┐
    ├──▶ EC2 instance 2  (port 3000)   ├── Auto Scaling Group (min 1 / desired 2 / max 4)
    └──▶ EC2 instance 3  (port 3000)  ─┘  ← launched automatically when CPU > 60 %
```

- The ASG starts with **2 instances** (desired capacity).
- A **target tracking policy** keeps average CPU at or below **60 %** by launching or terminating instances automatically.
- New instances are bootstrapped via `user-data.sh` and registered with the ALB target group automatically — no manual steps.
- The ALB health-checks `/health` every 15 s and only routes traffic to healthy targets.

### Scaling policy

| Setting | Value |
|---------|-------|
| Policy type | Target Tracking |
| Metric | `ASGAverageCPUUtilization` |
| Target | 60 % |
| Min instances | 1 |
| Desired instances | 2 |
| Max instances | 4 |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6
- [Artillery](https://www.artillery.io/docs/get-started/get-artillery) (`npm install -g artillery`)
- AWS credentials configured (`aws configure` or env vars)

---

## Live demo walkthrough

### 1 — Deploy the infrastructure

```bash
cd terraform
terraform init
terraform apply
```

Note the outputs:

```
asg_name     = "scale-demo-asg"
alb_dns_name = "scale-demo-alb-1234567890.us-east-1.elb.amazonaws.com"
app_url      = "http://scale-demo-alb-1234567890.us-east-1.elb.amazonaws.com"
```

### 2 — Wait for the initial instances to start (~90 s)

Both instances launched by the ASG run `user-data.sh` on first boot to install Node.js and start the app via PM2. The ALB waits for each target to pass 2 consecutive health checks before sending traffic.

```bash
# Poll until you get a 200 through the ALB
curl $(terraform output -raw health_url)
# {"status":"ok","instance":"i-0abc..."}
```

### 3 — Show the ASG and ALB in the console

**EC2 → Auto Scaling Groups → `scale-demo-asg`:**
- Check the **Activity** tab — shows instance launches and terminations.
- Check the **Instance management** tab — shows all running instances and their health status.

**EC2 → Load Balancers → Target Groups → `scale-demo-tg`:**
- All initial instances should show **healthy**.

```bash
# Hit /health a few times to see the ALB rotating across instances
curl "$(terraform output -raw health_url)"
# {"status":"ok","instance":"i-0abc..."}   ← instance 1

curl "$(terraform output -raw health_url)"
# {"status":"ok","instance":"i-0xyz..."}   ← instance 2
```

### 4 — Open CloudWatch in the console

AWS Console → EC2 → Auto Scaling Groups → `scale-demo-asg` → **Monitoring** tab.

Metrics to watch:
- **Group In Service Instances** — will increase as the ASG scales out
- **Group Desired Capacity** — rises when the policy fires
- **CPUUtilization (per instance)** — climbs during load, drops as new instances join

> **Caveat — T2 CPU credit throttling**
>
> `t2.*` instances use a **credit-based bursting model**. Once credits are exhausted, AWS throttles
> the vCPU to 10 % at the hypervisor level. All instances in this demo have `cpu_credits = "unlimited"`
> configured in the launch template, which disables throttling and lets CPU reach 100 % freely.

### 5 — Run the load test

```bash
cd ../load-test
export TARGET_URL=$(cd ../terraform && terraform output -raw app_url)
artillery run artillery.yml

# Save results to JSON for later analysis
artillery run artillery.yml --output report.json

# Generate an HTML report from the JSON output
artillery report report.json
```

Artillery runs three phases designed to trigger and observe the ASG scale-out:

| Phase | Duration | Rate | What to expect |
|-------|----------|------|----------------|
| Warm up | 30 s | 5 req/s | Low CPU, 0 errors, 2 instances serving |
| Ramp up | 60 s | 5 → 70 req/s | CPU crosses 60 %, scaling policy fires |
| Sustained | 240 s | 70 req/s | New instances join, errors drop, CPU stabilizes |

> **Why 240 s sustained?** The ASG needs time to detect high CPU (CloudWatch aggregates over 1–3 min),
> launch a new instance (~90 s boot + health checks), and register it with the ALB. The 4-minute
> window is enough to watch the full scale-out play out in real time.

**What to show the audience:**
1. During *Warm up* — stable responses, 2 instances healthy in the target group.
2. During *Ramp up* — CPU climbs past 60 %, the ASG scaling policy triggers. Watch **Desired Capacity** increase in CloudWatch.
3. During *Sustained* — a new instance boots and joins the target group. Artillery error rate drops and latency improves **without any manual action**. That's the key demo moment.

### 6 — Clean up

```bash
cd ../terraform
terraform destroy
```

---

## Key takeaway for the talk

> With an ASG, the fleet size is no longer a fixed decision made at deploy time.
> AWS watches CPU continuously and adjusts capacity to match demand — scaling out under load
> and scaling back in when traffic drops to avoid unnecessary cost.
>
> The application didn't change. The infrastructure became elastic.

---

## Branch roadmap

| Branch | What it adds |
|--------|--------------|
| `main` | Single EC2, no load balancer |
| `01-implement-alb` | ALB in front of two fixed EC2s |
| `02-saturate-alb` | Push the fixed fleet past its ceiling |
| `03-auto-scaling-group` | ← you are here — ASG with CPU-based scaling policy |
| `04-right-sizing` | Choosing the right instance type before scaling out |
