#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

echo "==> Installing Node.js 20"
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
dnf install -y nodejs

echo "==> Installing PM2"
npm install -g pm2

echo "==> Creating app directory"
mkdir -p /opt/app
cd /opt/app

echo "==> Writing package.json"
cat > package.json << 'PKGJSON'
{
  "name": "demo-app",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "express": "^4.18.0" }
}
PKGJSON

echo "==> Writing server.js"
cat > server.js << 'APPJS'
const express = require('express')
const http = require('http')
const app = express()
const PORT = 3000

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
    }).on('error', () => {})
  })
})
tokenReq.on('error', () => {})
tokenReq.end()

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

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', instance: instanceId })
})

app.get('/work', (req, res) => {
  const limit = Math.min(parseInt(req.query.limit) || 20000, 50000)
  const start = Date.now()
  const primes = calculatePrimes(limit)
  const elapsed = Date.now() - start
  res.json({ instance: instanceId, limit, primesFound: primes.length, elapsed: `${elapsed}ms` })
})

app.listen(PORT, () => console.log(`Demo app listening on port ${PORT}`))
APPJS

echo "==> Installing dependencies"
npm install

echo "==> Starting app with PM2"
pm2 start server.js --name demo-app
pm2 startup systemd -u root --hp /root
pm2 save

echo "==> Done. App running on port 3000."
