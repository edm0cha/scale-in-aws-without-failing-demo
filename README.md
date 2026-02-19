# Does my application need balancing? — Demo Branch 1

> **Branch:** `01-single-ec2-no-scaling`
>
> A single `t2.micro` EC2, no load balancer, no Auto Scaling.
> We'll show how quickly a modest amount of traffic saturates it.

---

## What's in this branch

| Path | Purpose |
|------|---------|
| `terraform/` | Infrastructure — EC2 + Security Group in us-east-1 |
| `app/` | Node.js app source (also embedded in `user-data.sh`) |
| `load-test/artillery.yml` | Artillery scenario that ramps traffic until the instance breaks |

### The app

Two endpoints:

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Liveness check — fast, always returns `200` |
| `GET /work` | **Synchronous** prime-number calculation. Blocks the event loop. On a `t2.micro`, each request takes ~300–600 ms. Under concurrent load, requests queue up, CPU hits 100 %, and response times explode. |

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
app_url = "http://1.2.3.4:3000"
```

### 2 — Wait for the app to start (~90 s)

The instance runs `user-data.sh` on first boot to install Node.js and start the app via PM2.

```bash
# Poll until you get a 200
curl $(terraform output -raw health_url)
# {"status":"ok","instance":"i-0abc..."}
```

### 3 — Show a single request working fine

```bash
curl "$(terraform output -raw work_url)"
# {"instance":"i-0abc...","limit":20000,"primesFound":2262,"elapsed":"312ms"}
```

**Talking point:** one request, one vCPU, ~300 ms. Feels fine.

### 4 — Open CloudWatch in the console

AWS Console → EC2 → Instances → select the instance → **Monitoring** tab.

> Enable **detailed monitoring** if you want 1-minute granularity (already enabled by Terraform).

Metrics to watch:
- **CPUUtilization** — will peg at 100 %
- **NetworkIn / NetworkOut** — will spike

### 5 — Run the load test

```bash
cd ../load-test
export TARGET_URL=$(cd ../terraform && terraform output -raw app_url)
artillery run artillery.yml
```

Artillery runs three phases:

| Phase | Duration | Rate |
|-------|----------|------|
| Warm up | 30 s | 1 req/s |
| Ramp up | 60 s | 1 → 30 req/s |
| Sustained | 90 s | 30 req/s |

**What to show the audience:**
1. During *Warm up* — response times are stable (~300–500 ms), 0 errors.
2. During *Ramp up* — watch CloudWatch CPU climb toward 100 %.
3. During *Sustained* — Artillery starts reporting `ETIMEDOUT` / `5xx` errors. The instance is saturated.

### 6 — Clean up

```bash
cd ../terraform
terraform destroy
```

---

## Key takeaway for the talk

> A single small instance can handle light, predictable traffic just fine.
> The moment traffic becomes concurrent or spiky, it fails — and there's nothing
> to absorb or distribute the load.
>
> That's the problem the next branches will solve.

---

## Branch roadmap

| Branch | What it adds |
|--------|--------------|
| `01-single-ec2-no-scaling` | ← you are here |
| `02-elb-fixed-fleet` | ALB in front of two fixed EC2s |
| `03-auto-scaling-group` | ASG with CPU-based scaling policy |
| `04-right-sizing` | Choosing the right instance type before scaling out |
