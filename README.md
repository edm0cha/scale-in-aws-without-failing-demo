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
| `terraform/` | Infrastructure — ASG + Launch Template + ALB + Security Groups + IAM instance role in us-east-1 |
| `app/` | Node.js app source (also embedded in `user-data.sh`) |
| `load-test/artillery.yml` | Artillery scenario that triggers and observes the ASG scale-out |
| `load-test/elb-saturation.json` | Baseline report from `02-saturate-alb` (no ASG) — used below to justify the thresholds |
| `load-test/report.json` | Report from this branch (ASG active) — same comparison |

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

- The ASG starts with **2 instances** (desired capacity).
- A **target tracking policy** keeps average CPU at or below **60 %** by launching or terminating instances automatically.
- New instances are bootstrapped via `user-data.sh` and registered with the ALB target group automatically — no manual steps.
- The ALB health-checks `/health` every 15 s and only routes traffic to healthy targets.

### Scaling policies

**CPU-based (reactive)** — responds to live traffic:

| Setting | Value |
|---------|-------|
| Policy type | Target Tracking |
| Metric | `ASGAverageCPUUtilization` |
| Target | 60 % |
| Min instances | 1 |
| Desired instances | 2 |
| Max instances | 4 |

**Memory-based (safety net)** — a second, independent signal:

| Setting | Value |
|---------|-------|
| Policy type | Target Tracking |
| Metric | `mem_used_percent` (custom, via CloudWatch Agent, namespace `CWAgent`) |
| Target | 75 % |
| Min / Desired / Max | same ASG — 1 / 2 / 4 |

**Scheduled (proactive)** — reduces cost during off-hours:

| Action | Time (UTC) | min | desired | Effect |
|--------|-----------|-----|---------|--------|
| Scale down | 10 PM daily (`0 22 * * *`) | 0 | 0 | All instances terminated |
| Scale up | 6 AM daily (`0 6 * * *`) | 1 | 1 | One instance started before peak traffic |

> All three policies coexist. The ASG scales out to satisfy *whichever* target-tracking policy is
> asking for the most capacity at any given moment — CPU and memory don't override each other, they
> each pull the desired capacity up independently. At night the scheduled actions override capacity
> to zero, eliminating idle instance costs entirely.

---

## Why these thresholds? (data-driven, not guessed)

A target-tracking value like "60 % CPU" looks arbitrary until you connect it to two things you can
actually measure: **what happens if you don't scale in time**, and **how long scaling takes**.

### 1 — What happens if you don't scale (the cost of getting it wrong)

`load-test/elb-saturation.json` is the Artillery report from `02-saturate-alb` — the **same app,
same workload, no ASG**, a fixed 2-instance fleet pushed past its ceiling. `load-test/report.json`
is a run from **this** branch, with the ASG's CPU target-tracking policy active.

| Metric | Fixed fleet, no ASG (`02`) | ASG, 60 % CPU target (`03`) |
|--------|---------------------------|------------------------------|
| Requests failed | 4,971 / 11,925 (**42 %**) — `ETIMEDOUT` | 0 / 3,660 (**0 %**) |
| Mean latency | 1,102 ms | 193 ms |
| p95 latency | 2,019 ms | 424 ms |
| p99 latency | 2,725 ms | 1,064 ms |
| Max latency | 9,808 ms | 2,491 ms |

**Talking point:** latency doesn't degrade linearly as CPU rises — it stays flat, then hits a knee,
then falls off a cliff into timeouts. The `02` numbers *are* that cliff. The whole point of a
threshold is to trigger *before* the fleet reaches it, not after.

### 2 — How long scaling takes (the buffer you need)

Every threshold has to leave enough headroom to survive the time it takes new capacity to come
online. For this stack that lag is the sum of:

| Step | Time |
|------|------|
| CloudWatch detects sustained high CPU (1-min detailed monitoring, needs a few consecutive datapoints) | ~1–3 min |
| Instance boots, runs `user-data.sh`, Node/PM2 start | ~90 s |
| ALB health checks pass (`healthy_threshold = 2` × `interval = 15s`) | ~30 s |
| **Total worst case** | **~3–5 min** |

During that whole window, the *existing* fleet is the only thing serving traffic — it has to absorb
any further growth on its own. That's exactly why `artillery.yml`'s "Sustained" phase holds load for
240 s: long enough to watch this lag play out live.

**The rule of thumb:** `target_value = 100 % − buffer`, where `buffer` has to cover how much traffic
can plausibly grow during that 3–5 min lag. A slow-booting `t2.micro` behind a bursty traffic pattern
needs a bigger buffer (lower target, e.g. 50–60 %) than a fast-scaling container fleet behind smooth
traffic (which can run a much higher target, e.g. 80 %). 60 % is the right call *here* because boot
time is slow and the load test intentionally ramps hard — not because 60 is a magic number.

> **Live during the talk:** open CloudWatch → the EC2 instance's **CPUUtilization** graph for the
> exact time window of the load test and lay it next to the Artillery latency graph from the same
> run. You'll see CPU cross 60 % right where latency starts climbing — that's the target-tracking
> policy firing in real time, before the fleet reaches the `02` cliff.

### 3 — Why memory gets a *different* target (75 %, not 60 %)

The `/work` endpoint is a synchronous prime sieve — pure CPU, no allocations that stick around, no
cache, no in-memory session store. Memory usage on this workload should stay low and flat under
load, no matter how hard you hit `/work`.

That's the point: **CPU is the primary bottleneck here, so it gets the tighter threshold. Memory is
a safety net**, sized with the generic industry default (~25 % headroom for OS + Node heap) rather
than derived from this workload's behavior — there's nothing in this app's memory profile to derive
a tighter number from.

> **Live during the talk:** watch the two metrics side by side while the load test runs — CPU climbs
> toward 60 % and triggers scaling, memory barely moves. That contrast **is** the lesson: a threshold
> should reflect which resource your workload actually exhausts first. A memory-bound service (a
> cache, a JVM app with a large heap, anything holding large payloads in memory) would flip this —
> memory becomes the tight, primary threshold, and CPU becomes the safety net instead.

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
- **Group In Service Instances** — will increase as the ASG scales out
- **Group Desired Capacity** — rises when the policy fires
- **CPUUtilization (per instance)** — climbs during load, drops as new instances join
- **`mem_used_percent`** — custom metric, namespace `CWAgent` (CloudWatch → All metrics → CWAgent →
  `AutoScalingGroupName`). Published every 60 s by the CloudWatch Agent installed via `user-data.sh`.
  Expect this to stay low and flat throughout the load test — see "Why memory gets a different
  target" further down this README.

> **Caveat — T2 CPU credit throttling**
>
> `t2.*` instances use a **credit-based bursting model**. Once credits are exhausted, AWS throttles
> the vCPU to 10 % at the hypervisor level. All instances in this demo have `cpu_credits = "unlimited"`
> configured in the launch template, which disables throttling and lets CPU reach 100 % freely.

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
