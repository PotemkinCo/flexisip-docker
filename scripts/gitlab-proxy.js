#!/usr/bin/env node
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { chromium } = require('playwright-core');

const PORT = parseInt(process.env.PROXY_PORT || '8843', 10);
const UPSTREAM = 'https://gitlab.linphone.org';
const CDP_URL = process.env.CDP_URL || 'http://127.0.0.1:9222';
const MAX_TRIES = parseInt(process.env.MAX_TRIES || '8', 10);
const CHROME_BIN = process.env.CHROME_BIN || '/usr/bin/google-chrome-stable';
const CDP_PORT = (() => { try { return parseInt(CDP_URL.split(':').pop(), 10); } catch { return 9222; } })();
// Chrome's CDP log goes to a writable temp dir (works locally and in CI).
const CHROME_LOG = process.env.CHROME_LOG || path.join(os.tmpdir(), 'gitlab_proxy_chrome_cdp.log');

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function chromeIsUp() {
  try {
    const res = await fetch(CDP_URL + '/json/version', { signal: AbortSignal.timeout(3000) });
    return res.ok;
  } catch { return false; }
}

async function ensureChrome() {
  if (await chromeIsUp()) { console.error('[proxy] chrome already up'); return; }
  const args = ['--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
    `--remote-debugging-port=${CDP_PORT}`, 'about:blank'];
  const log = fs.openSync(CHROME_LOG, 'a');
  const child = spawn(CHROME_BIN, args, { detached: true, stdio: ['ignore', log, log] });
  child.unref();
  console.error('[proxy] launched chrome (pid ' + child.pid + '), waiting for CDP...');
  for (let i = 0; i < 40; i++) {
    if (await chromeIsUp()) { console.error('[proxy] chrome CDP ready'); return; }
    await sleep(500);
  }
  throw new Error('chrome did not become reachable on ' + CDP_URL);
}

function filterHopByHop(h) {
  const out = {};
  for (const [k, v] of Object.entries(h)) {
    const lk = k.toLowerCase();
    if (['host', 'connection', 'content-length', 'transfer-encoding', 'proxy-connection', 'accept-encoding'].includes(lk)) continue;
    out[k] = v;
  }
  return out;
}

// Runs inside the page (origin = UPSTREAM => same-origin fetch, no CORS).
function pageFetch(args) {
  const { url, method, headers, body } = args;
  const init = { method, headers: headers || {}, redirect: 'follow' };
  if (body && body.length) init.body = (body instanceof Uint8Array) ? body : new Uint8Array(body);
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 9 * 60 * 1000);
  return fetch(url, { ...init, signal: ctrl.signal }).then(async (r) => {
    clearTimeout(t);
    const buf = new Uint8Array(await r.arrayBuffer());
    return { status: r.status, headers: Object.fromEntries(r.headers.entries()), body: buf };
  });
}

async function ensureOrigin(page) {
  for (let i = 0; i < MAX_TRIES; i++) {
    if (page.url() && page.url().startsWith(UPSTREAM)) return true;
    try {
      await page.goto(UPSTREAM + '/explore/projects', { waitUntil: 'domcontentloaded', timeout: 20000 });
      if (page.url().startsWith(UPSTREAM)) return true;
    } catch (e) { /* retry */ }
    await sleep(700);
  }
  return page.url().startsWith(UPSTREAM);
}

async function fetchWithRetry(page, payload) {
  let lastErr;
  for (let i = 0; i < MAX_TRIES; i++) {
    try {
      if (!page.url().startsWith(UPSTREAM)) await ensureOrigin(page);
      return await page.evaluate(pageFetch, payload);
    } catch (e) {
      lastErr = e;
      const msg = String(e.message || e);
      if (/ERR_ADDRESS_UNREACHABLE|Timeout|net::|aborted|Navigation|interrupted|Failed to fetch|TypeError|ECONN|socket/i.test(msg)) {
        await sleep(800);
        continue;
      }
      throw e;
    }
  }
  throw lastErr;
}

async function main() {
  await ensureChrome();
  const browser = await chromium.connectOverCDP(CDP_URL);
  const context = browser.contexts()[0] || await browser.newContext();
  const page = context.pages()[0] || await context.newPage();
  console.error('[proxy] establishing origin (may need retries due to intermittent egress)...');
  const ok = await ensureOrigin(page);
  console.error('[proxy] origin ready:', ok, 'url=', page.url());

  const server = http.createServer(async (req, res) => {
    const upstream = UPSTREAM + req.url;
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);
    const headers = filterHopByHop(req.headers);
    console.error(`[proxy] ${req.method} ${req.url}`);
    try {
      const result = await fetchWithRetry(page, { url: upstream, method: req.method, headers, body: body.length ? Array.from(body) : undefined });
      const pass = {};
      for (const [k, v] of Object.entries(result.headers)) {
        const lk = k.toLowerCase();
        if (['content-length', 'content-encoding', 'transfer-encoding', 'connection', 'keep-alive', 'access-control-allow-origin'].includes(lk)) continue;
        pass[k] = v;
      }
      const buf = Buffer.isBuffer(result.body) ? result.body : Buffer.from(result.body);
      res.writeHead(result.status, pass);
      res.end(buf);
    } catch (e) {
      console.error('[proxy] fetch error:', e.message);
      if (!res.headersSent) res.writeHead(502);
      res.end('upstream fetch failed: ' + e.message);
    }
  });

  server.listen(PORT, '127.0.0.1', () => {
    console.error(`[proxy] listening on http://127.0.0.1:${PORT}  (git over Chrome QUIC/TCP -> ${UPSTREAM})`);
  });
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
