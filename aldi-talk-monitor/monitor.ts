#!/usr/bin/env bun
/**
 * ALDI TALK data balance checker with auto-refill.
 * Zero dependencies — runs with: bun monitor.ts
 */

const USERNAME = process.env.ALDI_TALK_USERNAME!;
const PASSWORD = process.env.ALDI_TALK_PASSWORD!;

const AUTH_BASE    = 'https://login.alditalk-kundenbetreuung.de';
const PORTAL_BASE  = 'https://www.alditalk-kundenportal.de';
const BACKEND_BASE = 'https://www.alditalk-kundenbetreuung.de';
const BFF          = `${PORTAL_BASE}/scs/bff/scs-209-selfcare-dashboard-bff/selfcare-dashboard/v1`;
const NAV_BFF      = `${PORTAL_BASE}/scs/bff/scs-207-customer-master-data-bff/customer-master-data/v1`;
const REFILL_URL   = `${BFF}/offer/updateUnlimited`;
const SESSION_FILE = `${import.meta.dir}/session.json`;
const STATE_FILE   = `${import.meta.dir}/state.json`;

// When remainKB >= FAST_RATIO * threshKB, slow-poll (SLOW_INTERVAL_MS between runs).
// Below that, the 15-min timer fires normally for prompt refill detection.
const FAST_RATIO        = 1.5;
const SLOW_INTERVAL_MS  = 2 * 60 * 60 * 1000; // 2 hours

const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const DEFAULT_HEADERS: Record<string, string> = {
  'User-Agent':      UA,
  'Accept':          'application/json, text/plain, */*',
  'Accept-Language': 'de-DE,de;q=0.9,en;q=0.8',
  'Accept-Encoding': 'gzip, br',
};

const PORTAL_HEADERS: Record<string, string> = {
  ...DEFAULT_HEADERS,
  'Origin':  PORTAL_BASE,
  'Referer': `${PORTAL_BASE}/user/auth/account-overview/`,
};

// ── Types ────────────────────────────────────────────────────────────────────

interface Callback {
  type: string;
  input?: Array<{ name: string; value: string | number }>;
  output?: Array<{ name: string; value: string }>;
}

interface AuthResponse {
  authId?: string;
  tokenId?: string;
  successUrl?: string;
  callbacks?: Callback[];
  code?: number;
  message?: string;
}

interface Pack {
  type: string;
  used: string;
  allocated: string;
  balanceAttributeReference: string;
  nextExpirationDate: string;
}

interface Offer {
  offerId: string;
  offerName: string;
  status: string;
  price: string;
  duration: string;
  renewalDate: string;
  resourceId: string;
  subscriptionId: string;
  isOnDemandRefillApplicable: boolean;
  refillThresholdValueUid: string;
  onDemandAmountValue: string;
  onDemandAmountValueUid: string;
  pack: Pack[];
}

interface OffersResponse {
  totalBalance: string;
  subscribedOffers: Offer[];
}

interface ParsedOffer {
  offer: Offer;
  remainKB: number | null;
  threshKB: number;
  refillAvailable: boolean;
  totalBalance: string;
}

interface RefillResponse {
  status: string;
  isUpdated: boolean;
  message?: string;
}

interface State {
  checkedAt: number;
  remainKB: number | null;
  threshKB: number;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

const jitter = (a: number, b: number) => new Promise(r => setTimeout(r, a + Math.random() * (b - a)));

// ── Adaptive polling state ────────────────────────────────────────────────────

async function loadState(): Promise<State | null> {
  try {
    return JSON.parse(await Bun.file(STATE_FILE).text()) as State;
  } catch {
    return null;
  }
}

async function saveState(state: State): Promise<void> {
  await Bun.write(STATE_FILE, JSON.stringify(state, null, 2));
}

function shouldSkip(state: State | null): boolean {
  if (!state || state.remainKB === null) return false;
  const age = Date.now() - state.checkedAt;
  const aboveThreshold = state.remainKB >= FAST_RATIO * state.threshKB;
  return aboveThreshold && age < SLOW_INTERVAL_MS;
}

// ── Cookie jar ───────────────────────────────────────────────────────────────

class CookieJar {
  private store = new Map<string, Map<string, string>>();

  set(domain: string, name: string, value: string): void {
    const d = domain.startsWith('.') ? domain.slice(1) : domain;
    if (!this.store.has(d)) this.store.set(d, new Map());
    this.store.get(d)!.set(name, value);
  }

  get(domain: string, name: string): string | undefined {
    const d = domain.startsWith('.') ? domain.slice(1) : domain;
    return this.store.get(d)?.get(name);
  }

  collect(responseUrl: string, headers: Headers): void {
    const hostname = new URL(responseUrl).hostname;
    for (const raw of headers.getSetCookie()) {
      const eqIdx   = raw.indexOf('=');
      const semIdx  = raw.indexOf(';');
      const name    = raw.slice(0, eqIdx).trim();
      const value   = raw.slice(eqIdx + 1, semIdx === -1 ? undefined : semIdx).trim();
      const attrs   = semIdx !== -1 ? raw.slice(semIdx + 1) : '';
      const domAttr = attrs.split(';').map(s => s.trim()).find(s => s.toLowerCase().startsWith('domain='));
      const domain  = domAttr ? domAttr.split('=')[1].trim() : hostname;
      this.set(domain, name, value);
    }
  }

  header(requestUrl: string): string {
    const { hostname } = new URL(requestUrl);
    return [...this.store.entries()]
      .filter(([d]) => hostname === d || hostname.endsWith(`.${d}`))
      .flatMap(([, cookies]) => [...cookies.entries()].map(([k, v]) => `${k}=${v}`))
      .join('; ');
  }

  toJSON(): Record<string, Record<string, string>> {
    return Object.fromEntries(
      [...this.store.entries()].map(([d, c]) => [d, Object.fromEntries(c)])
    );
  }

  static fromJSON(json: Record<string, Record<string, string>>): CookieJar {
    const jar = new CookieJar();
    for (const [domain, cookies] of Object.entries(json))
      for (const [name, value] of Object.entries(cookies))
        jar.set(domain, name, value);
    return jar;
  }
}

// ── Session persistence ──────────────────────────────────────────────────────

async function saveSession(jar: CookieJar): Promise<void> {
  await Bun.write(SESSION_FILE, JSON.stringify(jar.toJSON(), null, 2));
}

async function loadSession(): Promise<CookieJar> {
  try {
    const text = await Bun.file(SESSION_FILE).text();
    process.stderr.write('Loaded saved session.\n');
    return CookieJar.fromJSON(JSON.parse(text));
  } catch {
    return new CookieJar();
  }
}

// ── HTTP helpers ─────────────────────────────────────────────────────────────

async function get(jar: CookieJar, url: string, extraHeaders?: Record<string, string>): Promise<Response> {
  const headers = new Headers({ ...DEFAULT_HEADERS, ...extraHeaders });
  const cookieStr = jar.header(url);
  if (cookieStr) headers.set('Cookie', cookieStr);
  const res = await fetch(url, { headers, redirect: 'manual' });
  jar.collect(url, res.headers);
  return res;
}

async function post(jar: CookieJar, url: string, body: unknown, extraHeaders?: Record<string, string>): Promise<Response> {
  const headers = new Headers({ ...DEFAULT_HEADERS, ...extraHeaders });
  headers.set('Content-Type', 'application/json');
  const cookieStr = jar.header(url);
  if (cookieStr) headers.set('Cookie', cookieStr);
  const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body), redirect: 'manual' });
  jar.collect(url, res.headers);
  return res;
}

async function followRedirects(jar: CookieJar, url: string, maxRedirects = 10): Promise<Response> {
  let current = url;
  let res!: Response;
  for (let i = 0; i <= maxRedirects; i++) {
    res = await get(jar, current);
    if (res.status < 300 || res.status >= 400) break;
    const location = res.headers.get('location');
    if (!location) break;
    current = location.startsWith('http') ? location : new URL(location, current).href;
  }
  return res;
}

// ── Crypto helpers ───────────────────────────────────────────────────────────

const toGB = (kb: number) => (kb / 1024 / 1024).toFixed(2);

function sha1(msg: string): string {
  return new Bun.CryptoHasher('sha1').update(msg).digest('hex') as string;
}

function solvePoW(uuid: string, difficulty: number): number {
  const target = '0'.repeat(difficulty);
  let nonce = 0;
  while (!sha1(uuid + nonce).startsWith(target)) nonce++;
  return nonce;
}

function randomBase64url(bytes = 32): string {
  const buf = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...buf)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

async function sha256Base64url(input: string): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return btoa(String.fromCharCode(...new Uint8Array(hash)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

// ── ForgeRock authentication ─────────────────────────────────────────────────

async function authenticate(jar: CookieJar): Promise<void> {
  const AUTH_URL = `${AUTH_BASE}/signin/json/realms/root/realms/alditalk/authenticate`;
  const authHeaders = {
    'Accept-API-Version': 'resource=2.1, protocol=1.0',
    'Referer': `${AUTH_BASE}/signin/XUI/#login/`,
    'Origin':  AUTH_BASE,
  };

  const authPost = async (body: unknown): Promise<AuthResponse> => {
    const res = await post(jar, AUTH_URL, body, authHeaders);
    return res.json() as Promise<AuthResponse>;
  };

  // Step 1: get initial callbacks
  const init = await authPost({});
  await jitter(200, 700);

  // Step 2: submit credentials → receive PoW challenge
  const withCreds = (callbacks: Callback[]): Callback[] =>
    callbacks.map(cb => {
      const val = (v: string | number) => [{ name: cb.input![0].name, value: v }];
      if (cb.type === 'NameCallback')         return { ...cb, input: val(USERNAME) };
      if (cb.type === 'PasswordCallback')     return { ...cb, input: val(PASSWORD) };
      if (cb.type === 'ConfirmationCallback') return { ...cb, input: val(2) };
      return cb;
    });

  const step1 = await authPost({ ...init, callbacks: withCreds(init.callbacks!) });
  await jitter(200, 700);

  // Step 3: solve Proof-of-Work and submit
  const script     = step1.callbacks!.find(c => c.type === 'TextOutputCallback')!.output![0].value;
  const uuid       = script.match(/var work = "([^"]+)"/)![1];
  const difficulty = parseInt(script.match(/var difficulty = (\d+)/)![1]);
  const nonce      = solvePoW(uuid, difficulty);
  process.stderr.write(`PoW solved: nonce=${nonce}\n`);

  const withPoW = (callbacks: Callback[]): Callback[] =>
    withCreds(callbacks).map(cb => {
      const isPoW = cb.output?.some(o => o.name === 'id' && o.value === 'proofOfWorkNonce');
      return isPoW ? { ...cb, input: [{ name: cb.input![0].name, value: String(nonce) }] } : cb;
    });

  const auth = await authPost({ ...step1, callbacks: withPoW(step1.callbacks!) });
  if (!auth.tokenId) throw new Error(`Auth failed: ${JSON.stringify(auth)}`);
  process.stderr.write('ForgeRock auth complete.\n');

  await jitter(200, 700);

  // Exchange ForgeRock session for portal session via OAuth2 PKCE
  const codeVerifier  = randomBase64url(48);
  const codeChallenge = await sha256Base64url(codeVerifier);

  const params = new URLSearchParams({
    client_id:             'U-567-b2p_portal',
    response_type:         'code',
    scope:                 'portal_care_profile multi_login u-672:consent:r u-672:consent:c u-672:consent:u u-672:profile:r openid',
    redirect_uri:          `${BACKEND_BASE}/openid/response`,
    code_challenge:        codeChallenge,
    code_challenge_method: 'S256',
    nonce:                 randomBase64url(16),
    state:                 randomBase64url(16),
    acr_values:            'password',
    ui_locales:            'de',
  });

  await followRedirects(jar, `${AUTH_BASE}/signin/oauth2/authorize?${params}`);
  process.stderr.write('Portal session established.\n');
}

// ── Contract discovery ───────────────────────────────────────────────────────

async function fetchContractId(jar: CookieJar): Promise<string> {
  // Derive msisdn from lgrs_id cookie: base64("4915785665123") → strip "49" prefix
  const lgrsId = jar.get('www.alditalk-kundenportal.de', 'lgrs_id');
  if (!lgrsId) throw new Error('lgrs_id cookie not found — session may be invalid');
  const e164   = atob(lgrsId);           // e.g. "4915785665123"
  const msisdn = e164.startsWith('49') ? e164.slice(2) : e164;

  const res  = await get(jar, `${NAV_BFF}/navigation-list?msisdn=${msisdn}`, PORTAL_HEADERS);
  const body = await res.text();
  if (!body.startsWith('{')) throw new Error(`Contract discovery failed (HTTP ${res.status}): ${body.slice(0, 100)}`);
  const data       = JSON.parse(body) as { userDetails?: { subscriptions?: Array<{ contractId: string }> } };
  const contractId = data.userDetails?.subscriptions?.[0]?.contractId;
  if (!contractId) throw new Error(`No contractId in navigation-list response: ${body.slice(0, 200)}`);
  return contractId;
}

// ── Offers API ───────────────────────────────────────────────────────────────

async function fetchOffers(jar: CookieJar, contractId: string): Promise<OffersResponse> {
  const url  = `${BFF}/offers?warningDays=28&contractId=${contractId}&productType=Mobile_Product_Offer`;
  const res  = await get(jar, url, PORTAL_HEADERS);
  const body = await res.text();
  if (!body.startsWith('{')) throw new Error(`Session expired (HTTP ${res.status})`);
  return JSON.parse(body) as OffersResponse;
}

// ── Parse & display ──────────────────────────────────────────────────────────

function parseOffers(data: OffersResponse): ParsedOffer[] {
  return data.subscribedOffers.map(offer => {
    const inland   = offer.pack?.find(p => p.balanceAttributeReference === 'dataGrantAmount');
    const remainKB = inland ? parseInt(inland.allocated) - parseInt(inland.used) : null;
    const threshKB = parseInt(offer.refillThresholdValueUid);
    return {
      offer,
      remainKB,
      threshKB,
      refillAvailable: offer.isOnDemandRefillApplicable && remainKB !== null && remainKB < threshKB,
      totalBalance: data.totalBalance,
    };
  });
}

function printDataBalance(parsed: ParsedOffer[]): void {
  const now = new Date().toLocaleString('de-DE', { timeZone: 'Europe/Berlin' });
  console.log(`Checked at: ${now}\n`);

  const labels: Record<string, string> = {
    dataGrantAmount:    'Inland data',
    dataGrantAmountFUP: 'EU roaming data',
  };

  for (const { offer, remainKB, threshKB, refillAvailable } of parsed) {
    const renewal = offer.renewalDate
      ? new Date(offer.renewalDate).toLocaleString('de-DE', { timeZone: 'Europe/Berlin' })
      : 'n/a';
    console.log(`Tariff:   ${offer.offerName}  (${offer.status})`);
    console.log(`Renewal:  ${renewal}`);
    console.log(`Price:    €${offer.price} / ${offer.duration}`);

    for (const pack of offer.pack ?? []) {
      if (pack.type !== 'data') continue;
      const label   = labels[pack.balanceAttributeReference] ?? pack.balanceAttributeReference;
      const usedKB  = parseInt(pack.used);
      const totalKB = parseInt(pack.allocated);
      const remKB   = totalKB - usedKB;
      const pct     = totalKB > 0 ? Math.round((remKB / totalKB) * 100) : 0;
      const expires = new Date(pack.nextExpirationDate).toLocaleString('de-DE', { timeZone: 'Europe/Berlin' });
      console.log(`  ${label}: ${toGB(remKB)} GB remaining of ${toGB(totalKB)} GB (${pct}%)  [expires ${expires}]`);
    }

    if (offer.isOnDemandRefillApplicable) {
      const status = refillAvailable
        ? '✓ available'
        : `not yet (need < ${toGB(threshKB)} GB, have ${toGB(remainKB!)} GB)`;
      console.log(`  Refill: ${status}`);
    }
  }

  console.log(`\nBalance:  €${parsed[0]?.totalBalance}`);
}

// ── Refill ───────────────────────────────────────────────────────────────────

async function triggerRefill(jar: CookieJar, offer: Offer): Promise<RefillResponse> {
  const res = await post(jar, REFILL_URL, {
    offerId:               offer.offerId,
    subscriptionId:        offer.subscriptionId,
    updateOfferResourceID: offer.resourceId,
    amount:                offer.onDemandAmountValueUid,
    refillThresholdValue:  offer.refillThresholdValueUid,
  }, PORTAL_HEADERS);
  const body = await res.text();
  if (!body.startsWith('{')) throw new Error(`Refill HTTP ${res.status}: ${body.slice(0, 100)}`);
  return JSON.parse(body) as RefillResponse;
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  // Adaptive polling: skip if balance was comfortable and checked recently
  const state = await loadState();
  if (shouldSkip(state)) {
    const nextAt = new Date(state!.checkedAt + SLOW_INTERVAL_MS).toLocaleString('de-DE', { timeZone: 'Europe/Berlin' });
    process.stderr.write(`Balance OK (${toGB(state!.remainKB!)} GB > ${FAST_RATIO}× threshold) — next full check at ${nextAt}\n`);
    return;
  }

  let jar = await loadSession();

  let contractId: string;
  let data: OffersResponse;
  try {
    contractId = await fetchContractId(jar);
    await jitter(200, 700);
    data = await fetchOffers(jar, contractId);
  } catch {
    process.stderr.write('Session expired — reauthenticating...\n');
    jar = new CookieJar();
    await authenticate(jar);
    await saveSession(jar);
    contractId = await fetchContractId(jar);
    await jitter(200, 700);
    data = await fetchOffers(jar, contractId);
  }

  const parsed = parseOffers(data);
  printDataBalance(parsed);

  // Persist state for adaptive polling
  const primary = parsed[0];
  if (primary) {
    await saveState({ checkedAt: Date.now(), remainKB: primary.remainKB, threshKB: primary.threshKB });
  }

  for (const { offer, refillAvailable } of parsed) {
    if (!refillAvailable) continue;
    await jitter(200, 700);
    process.stderr.write(`Triggering refill for ${offer.offerName}...\n`);
    const refill = await triggerRefill(jar, offer);
    if (refill.status === '200' && refill.isUpdated) {
      console.log(`\nRefill: +${offer.onDemandAmountValue} added successfully.`);
      await saveSession(jar);
      // Force fast polling after a refill to confirm the new balance
      await saveState({ checkedAt: 0, remainKB: null, threshKB: 0 });
    } else {
      console.log(`\nRefill: failed — ${refill.message ?? JSON.stringify(refill)}`);
    }
  }
}

main().catch(err => { console.error(err); process.exit(1); });
