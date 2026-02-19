const express = require('express')
const http = require('http')
const app = express()
const PORT = 3000

// Fetch instance metadata (only works on EC2; falls back to 'local' elsewhere)
let instanceId = 'local'
http.get('http://169.254.169.254/latest/meta-data/instance-id', (res) => {
  let data = ''
  res.on('data', (chunk) => { data += chunk })
  res.on('end', () => { instanceId = data.trim() })
}).on('error', () => { /* running locally, keep default */ })

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
