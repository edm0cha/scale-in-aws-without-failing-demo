const express = require('express')
const http = require('http')
const app = express()
const PORT = 3000

// Fetch instance ID using IMDSv2 (required on Amazon Linux 2023)
// Step 1: PUT to get a session token, then Step 2: GET the instance ID with that token
let instanceId = 'local'
const tokenReq = http.request({
  hostname: '169.254.169.254',
  path: '/latest/api/token',
  method: 'PUT',
  headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '21600' }
}, (tokenRes) => {
  let token = ''
  tokenRes.on('data', (chunk) => { token += chunk })
  tokenRes.on('end', () => {
    http.get({
      hostname: '169.254.169.254',
      path: '/latest/meta-data/instance-id',
      headers: { 'X-aws-ec2-metadata-token': token.trim() }
    }, (res) => {
      let data = ''
      res.on('data', (chunk) => { data += chunk })
      res.on('end', () => { instanceId = data.trim() })
    }).on('error', () => { /* running locally, keep default */ })
  })
})
tokenReq.on('error', () => { /* running locally, keep default */ })
tokenReq.end()

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Synchronous, intentionally naive prime sieve.
 * Blocks the event loop — that's the point.
 * On a t2.micro, limit=20000 takes ~300-600 ms per request.
 */
function calculatePrimes(limit) {
  const primes = []
  for (let n = 2; n <= limit; n++) {
    let prime = true
    for (let i = 2; i < n; i++) {
      if (n % i === 0) { prime = false; break }
    }
    if (prime) primes.push(n)
  }
  return primes
}

// ─── Routes ───────────────────────────────────────────────────────────────────

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', instance: instanceId })
})

/**
 * CPU-intensive endpoint.
 * Query param: ?limit=<number>  (default 20000)
 *
 * At low concurrency it responds in a few hundred ms.
 * Under load, requests queue up, response times spike, and the
 * instance CPU pegs at 100 % — visible in CloudWatch instantly.
 */
app.get('/work', (req, res) => {
  const limit = Math.min(parseInt(req.query.limit) || 20000, 50000)
  const start = Date.now()
  const primes = calculatePrimes(limit)
  const elapsed = Date.now() - start

  res.json({
    instance: instanceId,
    limit,
    primesFound: primes.length,
    elapsed: `${elapsed}ms`,
  })
})

// ─── Start ────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Demo app listening on port ${PORT}`)
  console.log(`  GET /health  — liveness check`)
  console.log(`  GET /work    — CPU-intensive endpoint (saturates t2.micro fast)`)
})
