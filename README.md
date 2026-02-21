# Does my application need balancing? — Saturating the ALB Fleet

> **Branch:** `02-saturate-alb`
>
> Two `t2.micro` EC2 instances behind an Application Load Balancer, no Auto Scaling.
> We'll prove that a fixed fleet has a hard ceiling — double the instances, double the breaking point,
> but it still breaks. The solution requires Auto Scaling.

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

Artillery runs three phases designed to push past the two-instance ceiling:

| Phase | Duration | Rate | Per instance |
|-------|----------|------|--------------|
| Warm up | 30 s | 5 req/s | ~2.5 req/s — comfortable |
| Ramp up | 90 s | 5 → 70 req/s | ~2.5 → 35 req/s — climbing |
| Saturate | 120 s | 70 req/s | ~35 req/s — past breaking point |

> **Why 70 req/s?** The single instance in `main` saturated at ~30 req/s. With two instances, each
> handles half the traffic, so 70 req/s puts ~35 req/s on each — just past the single-instance
> breaking point. Both instances saturate, errors and timeouts return.

**What to show the audience:**
1. During *Warm up* — both instances respond fast, 0 errors. The fleet has headroom.
2. During *Ramp up* — watch both CPUs climb in CloudWatch in parallel. Note how much higher the load gets before errors appear compared to `main`.
3. During *Saturate* — `ETIMEDOUT` errors return. The fleet hit its ceiling. Adding a third instance manually would only delay the problem — what we need is Auto Scaling.

### 6 — Clean up

```bash
cd ../terraform
terraform destroy
```

---

## Key takeaway for the talk

> A fixed fleet behind an ALB scales linearly — two instances handle twice the load of one.
> But it still has a hard ceiling. Once every instance is saturated, errors return just like before.
>
> Manually adding more instances is not a strategy — traffic is unpredictable and you can't be
> watching CloudWatch at 3 AM. The next branch introduces Auto Scaling to let AWS do it automatically.

---

## Branch roadmap

| Branch | What it adds |
|--------|--------------|
| `main` | Single EC2, no load balancer |
| `01-implement-alb` | ALB in front of two fixed EC2s |
| `02-saturate-alb` | ← you are here — push the fixed fleet past its ceiling |
| `03-auto-scaling-group` | ASG with CPU-based scaling policy |
| `04-right-sizing` | Choosing the right instance type before scaling out |
