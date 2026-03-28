# Debugging the ALDI Talk Portal with Playwright

When the headless `monitor.ts` breaks — wrong endpoint, changed payload, new auth step — the
fastest way to investigate is to replay the flow in a real browser via Playwright. The browser
shares cookies with the page, so `fetch()` calls made from `page.evaluate()` automatically carry
the right session, making it trivial to probe any API without re-implementing auth.

## Setup

```bash
cd ~/playwright-workspace
npm install playwright-core   # already done
```

Find the Chromium binary Nix built:

```bash
ls /nix/store/ | grep playwright-chromium | grep -v drv
# → 83bswbd6mcf088x4z92mdjjh9hqc0cyp-playwright-chromium
```

Set `executablePath` in every script to `/nix/store/<hash>-playwright-chromium/chrome-linux/chrome`.

---

## 1. Authenticate

The portal uses a 3-step ForgeRock OpenAM flow, followed by an OAuth2 redirect. Playwright
sidesteps the OAuth redirect complexity by just running the `fetch` calls inside the browser
context (which already holds all cookies from the page visit).

```js
const { chromium } = require('playwright-core');
const crypto = require('crypto');
const path = require('path');

function sha1(msg) { return crypto.createHash('sha1').update(msg).digest('hex'); }
function solvePoW(uuid, difficulty) {
  const target = '0'.repeat(difficulty);
  let nonce = 0;
  while (!sha1(uuid + nonce).startsWith(target)) nonce++;
  return nonce;
}

// All three ForgeRock steps run as fetch() inside the browser so cookies propagate automatically.
async function login(page) {
  const url = 'https://login.alditalk-kundenbetreuung.de/signin/json/realms/root/realms/alditalk/authenticate';
  const post = (payload) => page.evaluate(async ({ url, p }) => {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept-API-Version': 'resource=2.1, protocol=1.0' },
      body: JSON.stringify(p),
    });
    return r.json();
  }, { url, p: payload });

  // Step 1 — get initial callback structure
  const init = await post({});

  // Step 2 — fill credentials; server returns a Proof-of-Work challenge
  const fill = (p) => {
    for (const cb of p.callbacks) {
      if (cb.type === 'NameCallback')         cb.input[0].value = process.env.USERNAME;
      if (cb.type === 'PasswordCallback')     cb.input[0].value = process.env.PASSWORD;
      if (cb.type === 'ConfirmationCallback') cb.input[0].value = 2;
    }
    return p;
  };
  const step1 = await post(fill(init));

  // Step 3 — solve PoW: SHA1(uuid + nonce) must start with `difficulty` zeros
  const script     = step1.callbacks.find(c => c.type === 'TextOutputCallback').output[0].value;
  const uuid       = script.match(/var work = "([^"]+)"/)[1];
  const difficulty = parseInt(script.match(/var difficulty = (\d+)/)[1]);
  const nonce      = solvePoW(uuid, difficulty);

  const p2 = JSON.parse(JSON.stringify(step1)); // deep-clone before mutating
  for (const cb of p2.callbacks) {
    if (cb.output?.find(o => o.name === 'id' && o.value === 'proofOfWorkNonce'))
      cb.input[0].value = String(nonce);
    if (cb.type === 'NameCallback')         cb.input[0].value = process.env.USERNAME;
    if (cb.type === 'PasswordCallback')     cb.input[0].value = process.env.PASSWORD;
    if (cb.type === 'ConfirmationCallback') cb.input[0].value = 2;
  }
  return post(p2); // returns { tokenId, successUrl }
}

(async () => {
  const context = await chromium.launchPersistentContext(
    path.join(__dirname, 'browser-data'), // reuse cookies between runs
    {
      executablePath: '/nix/store/83bswbd6mcf088x4z92mdjjh9hqc0cyp-playwright-chromium/chrome-linux/chrome',
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-blink-features=AutomationControlled'],
      headless: true,
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      ignoreHTTPSErrors: true,
    }
  );

  const page = await context.newPage();

  // Visit the login page first so the browser picks up auth-domain cookies
  await page.goto('https://login.alditalk-kundenbetreuung.de/signin/XUI/#login/', {
    waitUntil: 'domcontentloaded', timeout: 30000,
  });
  await page.waitForTimeout(2000);

  // Accept cookie banner if present
  const acceptBtn = page.locator('button:has-text("Akzeptieren")');
  if (await acceptBtn.isVisible()) { await acceptBtn.click(); await page.waitForTimeout(500); }

  const auth = await login(page);
  // auth.successUrl redirects through OAuth2 and lands on the portal
  await page.goto(auth.successUrl, { waitUntil: 'networkidle', timeout: 30000 });

  // Now the browser is fully authenticated — do your investigation here
  await context.close();
})();
```

**Why `launchPersistentContext`?** It saves session cookies to `browser-data/` between runs.
Subsequent runs skip re-auth as long as the session is valid (typically several hours).

**Why `--disable-blink-features=AutomationControlled`?** The portal's Cloudflare bot detection
checks `navigator.webdriver`. Without this flag some pages return 403.

---

## 2. Sniff all API calls on a page

Attach `context.on('response', …)` *before* navigating. Filter out assets to keep the output
readable.

```js
const responses = [];
context.on('response', async res => {
  const url = res.url();
  if (res.request().method() === 'OPTIONS') return;
  if (url.match(/\.(js|css|png|svg|woff|ico|gif|jpg)(\?|$)/)) return;
  if (url.includes('google') || url.includes('usercentrics') || url.includes('gtm')) return;

  const ct = res.headers()['content-type'] ?? '';
  const body = ct.includes('json') ? await res.text() : null;
  responses.push({ status: res.status(), method: res.request().method(), url, body });
});

await page.goto('https://www.alditalk-kundenportal.de/user/auth/account-overview/', {
  waitUntil: 'networkidle', timeout: 30000,
});
await page.waitForTimeout(3000);

for (const r of responses) {
  console.log(`[${r.status}] ${r.method} ${r.url}`);
  if (r.body) console.log(' ', r.body.slice(0, 300));
}
```

Look for BFF patterns: `/scs/bff/scs-20X-*-bff/`. Each number is a different micro-service:
- `scs-207` — customer master data (navigation, subscriptions)
- `scs-208` — subscription management
- `scs-209` — selfcare dashboard (data balance, offers, refill)
- `scs-215` — additional services

---

## 3. Probe an endpoint without leaving the page

Because `page.evaluate()` runs inside the browser, all cookies are automatically included.
This is the fastest way to test an endpoint you found in the network log.

```js
const data = await page.evaluate(async () => {
  const r = await fetch(
    '/scs/bff/scs-207-customer-master-data-bff/customer-master-data/v1/navigation-list?msisdn=15785665123'
  );
  return r.json();
});
console.log(JSON.stringify(data.userDetails?.subscriptions, null, 2));
```

Use relative URLs — the browser knows the origin so you don't need to repeat the base.

---

## 4. Block page navigation to capture POST payloads

Some actions (refill button, tariff change) trigger a full-page reload, which kills the response
listener before it can capture the API call. Block document navigations while keeping XHR/fetch
through.

```js
const overviewUrl = page.url();
await page.route('**/*', async (route) => {
  const isDocNav =
    route.request().resourceType() === 'document' &&
    route.request().url() !== overviewUrl;

  if (isDocNav) {
    process.stderr.write(`Blocked navigation to: ${route.request().url()}\n`);
    await route.abort();
  } else {
    await route.continue();
  }
});
```

Set this up *after* the page has fully loaded, so the initial document request is not blocked.

---

## 5. Click buttons inside Shadow DOM

The portal uses Web Components (`<one-button>`, `<one-input>`, etc.). Standard Playwright
locators cannot see inside shadow roots. Use `page.evaluate()` to walk the DOM manually.

```js
// Find and click a <one-button> by its text content
const clicked = await page.evaluate((label) => {
  const btns = [...document.querySelectorAll('one-button')];
  const target = btns.find(el => el.textContent?.trim() === label);
  if (!target) return false;
  // The <button> lives inside the shadow root
  const inner = target.shadowRoot?.querySelector('button') ?? target;
  inner.click();
  return true;
}, '1 GB');

console.log('Clicked:', clicked);
await page.waitForTimeout(3000); // give the XHR time to complete
```

`el.textContent` on the host element includes slotted text; `el.innerText` inside the shadow
root returns empty.

---

## 6. Downloading and reading MFE bundles

The portal lazy-loads micro-frontend bundles from `mfe.o9.de`. These contain the actual business
logic: endpoint paths, payload shapes, threshold checks.

```js
// Capture MFE JS URLs while the page loads
const mfeUrls = [];
context.on('response', res => {
  if (res.url().includes('mfe.o9.de') && res.url().endsWith('.js'))
    mfeUrls.push(res.url());
});

await page.goto('https://www.alditalk-kundenportal.de/user/auth/account-overview/', {
  waitUntil: 'networkidle',
});

// Download the bundle that interests you
const { execSync } = require('child_process');
for (const url of mfeUrls) {
  const name = url.split('/').pop();
  execSync(`curl -s '${url}' -o ${name}`);
  console.log('Saved:', name);
}
```

Once you have the file, search for the endpoint pattern:

```bash
# Find BFF paths
grep -o 'scs/bff/[^"'\''`]*' mfe-mfe-account-overview.js | sort -u

# Find the refill function
grep -o 'updateUnlimited[^;]*' mfe-mfe-account-overview.js

# Prettify with a formatter to read the logic
npx prettier --parser babel mfe-mfe-account-overview.js > pretty.js
```

---

## 7. Export cookies from the browser for use in headless fetch

Once you have a working browser session, you can copy the cookies into the format `monitor.ts`
uses for its `session.json`:

```js
const cookies = await context.cookies();
const jar = {};
for (const c of cookies) {
  const domain = c.domain.startsWith('.') ? c.domain.slice(1) : c.domain;
  if (!jar[domain]) jar[domain] = {};
  jar[domain][c.name] = c.value;
}
require('fs').writeFileSync('session.json', JSON.stringify(jar, null, 2));
console.log('Session saved.');
```

This bootstraps `monitor.ts` without going through ForgeRock + PoW from scratch.

---

## Quick reference

| Goal | Technique |
|---|---|
| Capture all API calls | `context.on('response', …)` before `page.goto` |
| Probe an endpoint with auth | `page.evaluate(() => fetch('/relative/path').then(r => r.json()))` |
| Block page reloads | `page.route('**/*', route => isDocNav ? route.abort() : route.continue())` |
| Click inside Shadow DOM | `page.evaluate(() => el.shadowRoot.querySelector('button').click())` |
| Find endpoints in minified JS | `grep -o 'scs/bff/[^"]*' bundle.js \| sort -u` |
| Bootstrap headless session | Export `context.cookies()` → `session.json` |
