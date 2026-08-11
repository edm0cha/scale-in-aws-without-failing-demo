# Does my application need balancing? — ALB + Fixed Fleet

> **Branch:** `feat/1-implement-alb`
>
> Two `t2.micro` EC2 instances behind an Application Load Balancer, no Auto Scaling.
> We'll show how distributing traffic across two instances reduces saturation compared to a single server.

---

## What's in this branch

| Path | Purpose |
|------|---------|
| `terraform/` | Infrastructure — 2× EC2 + ALB + Security Groups in us-east-1 |
| `app/` | Node.js app source (also embedded in `user-data.sh`) |
| `load-test/artillery.yml` | Artillery scenario that ramps traffic until the fleet breaks |

### The app

Two endpoints:

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Liveness check — returns `200` and the responding `instance` ID |
| `GET /work` | **Synchronous** prime-number calculation. Blocks the event loop. On a `t2.micro`, each request takes ~300–600 ms. Under concurrent load, requests queue up, CPU hits 100 %, and response times explode. |

### The infrastructure

```
Internet
    │
    ▼
Application Load Balancer  (port 80)
    │
    ├──▶ EC2 instance 1  (port 3000)
    └──▶ EC2 instance 2  (port 3000)
```

- The ALB round-robins requests across both instances.
- Each instance handles ~half the load, so CPU per instance stays lower.
- The ALB health-checks `/health` every 15 s and stops routing to any instance that fails.

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

Note the outputs — you'll need `app_url`:

```
alb_dns_name  = "scale-demo-alb-1234567890.us-east-1.elb.amazonaws.com"
app_url       = "http://scale-demo-alb-1234567890.us-east-1.elb.amazonaws.com"
instance_id   = "i-0abc..."
instance_id_2 = "i-0xyz..."
```

### 2 — Wait for both instances to start (~90 s)

Both instances run `user-data.sh` on first boot to install Node.js and start the app via PM2.
The ALB waits for each target to pass 2 consecutive health checks before sending traffic to it.

```bash
# Poll until you get a 200 through the ALB
curl $(terraform output -raw health_url)
# {"status":"ok","instance":"i-0abc..."}
```

### 3 — Show the ALB distributing requests across both instances

```bash
curl "$(terraform output -raw health_url)"
# {"status":"ok","instance":"i-0abc..."}   ← instance 1

curl "$(terraform output -raw health_url)"
# {"status":"ok","instance":"i-0xyz..."}   ← instance 2
```

**Talking point:** the `instance` field alternates — the ALB is splitting traffic across both servers.

```bash
curl "$(terraform output -raw work_url)"
# {"instance":"i-0abc...","limit":20000,"primesFound":2262,"elapsed":"312ms"}
```

### 4 — Open CloudWatch in the console

AWS Console → EC2 → Instances → select **both** instances → **Monitoring** tab.

> Enable **detailed monitoring** if you want 1-minute granularity (already enabled by Terraform).

Metrics to watch on each instance:
- **CPUUtilization** — both instances share the load, so CPU climbs slower than on a single server
- **NetworkIn / NetworkOut** — will spike on both

> **Caveat — T2 CPU credit throttling**
>
> `t2.*` instances use a **credit-based bursting model**. At rest, a `t2.micro` earns credits that allow it to burst above its 10 % CPU baseline. Once those credits are exhausted, **AWS throttles the vCPU back to 10 % at the hypervisor level** — below the OS and below anything you can observe from inside the instance.
>
> This means CloudWatch may show a surprisingly low CPU percentage (e.g. 10–20 %) even while the server is completely saturated and returning timeouts. The instance isn't idle — it's being throttled.
>
> Both instances have `cpu_credits = "unlimited"` configured in Terraform, which disables this throttling and allows CPU to reach 100 % freely.

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

Artillery runs three phases:

| Phase | Duration | Rate |
|-------|----------|------|
| Warm up | 30 s | 1 req/s |
| Ramp up | 60 s | 1 → 30 req/s |
| Sustained | 90 s | 30 req/s |

**What to show the audience:**
1. During *Warm up* — response times are stable (~300–500 ms), 0 errors.
2. During *Ramp up* — watch CloudWatch CPU climb on both instances, but slower than before.
3. During *Sustained* — compare error rate and p99 latency to the `main` branch results. Both instances are sharing the load, so the fleet handles more traffic before degrading.

### 6 — Clean up

```bash
cd ../terraform
terraform destroy
```

---

## Key takeaway for the talk

> Adding a second instance behind an ALB doubles the capacity of the fleet.
> Response times improve and errors drop because each server handles half the requests.
>
> But the fleet size is still **fixed** — if traffic keeps growing, both instances will eventually
> saturate. That's the problem the next branch solves with Auto Scaling.

---

## Branch roadmap

| Branch | What it adds |
|--------|--------------|
| `main` | Single EC2, no load balancer |
| `feat/1-implement-alb` | ← you are here — ALB in front of two fixed EC2s |
| `03-auto-scaling-group` | ASG with CPU-based scaling policy |
| `04-right-sizing` | Choosing the right instance type before scaling out |
