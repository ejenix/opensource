// Copyright (c) Ejenix authors. MIT license.

/// The control-plane dashboard: a single self-contained HTML page (no build
/// step, no external assets, no webfonts) served at `/`. It drives the same
/// `/v1` JSON API the CLI uses, so an operator can list apps, promote a bundle
/// to an environment, and roll back — from a browser, right after `./deploy.sh`.
///
/// The admin key is entered once and kept in `localStorage`, sent as a bearer
/// token on every request. Nothing here is privileged on its own; the server
/// enforces auth.
///
/// Every number on the page comes from the API — `/v1/apps`, `/v1/apps/<id>/
/// envs`, `/v1/apps/<id>/bundles`, `/v1/health`, `/metrics`. The page shows what
/// this control plane actually knows and nothing it does not: an operator has to
/// be able to trust a dashboard that says a bundle is live.
const dashboardHtml = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ejenix — control plane</title>
<!-- The mark again, inline, so the tab is branded without an asset request. -->
<link rel="icon" href="/brand/logo.png">
<meta name="theme-color" content="#efeae0">
<style>
  /* The console's typefaces, served from this binary — no third-party request,
     and identical rendering on an air-gapped deployment. Both are variable
     fonts covering 400-700 in one file, latin subset. SIL OFL; see
     THIRD_PARTY_NOTICES.md. */
  @font-face {
    font-family: "Inter";
    src: url("/brand/inter.woff2") format("woff2");
    font-weight: 400 700; font-style: normal; font-display: swap;
  }
  @font-face {
    font-family: "JetBrains Mono";
    src: url("/brand/jetbrains-mono.woff2") format("woff2");
    font-weight: 400 700; font-style: normal; font-display: swap;
  }
  :root {
    color-scheme: light;
    --bg:        #efeae0;
    --panel:     #f7f5ee;
    --panel-2:   #f2efe6;
    --sidebar:   #131313;
    --sidebar-2: #1e1e1e;
    --ink:       #17150f;
    --ink-soft:  #4a453b;
    --muted:     #6e6759;
    --line:      #ded7c8;
    --line-soft: #e7e1d4;
    --purple:    #6d28d9;
    --purple-hi: #7c3aed;
    --purple-sf: #e6dff9;
    --purple-ln: #cdbdf2;
    --amber-sf:  #f7e9cc;
    --amber-ln:  #e3c98d;
    --amber-ink: #8a6410;
    --green-sf:  #dbeee0;
    --green-ink: #1e7a3e;
    --red:       #c0392b;
    --red-sf:    #fbe4e1;
    --mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    --sans: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  /* Inter needs its optical tweaks on to look like Inter rather than a
     generic grotesque: contextual alternates, and tabular figures wherever a
     number sits in a column. */
  body { font-feature-settings: "cv05" 1, "cv08" 1, "calt" 1; }
  .cell .v, td.num, .mono, .meta .v, .crumb { font-variant-numeric: tabular-nums; }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.55 var(--sans);
    display: grid; grid-template-columns: 272px 1fr;
  }
  a { color: inherit; }
  button, input, select { font: inherit; }

  /* ---------------------------------------------------------- sidebar --- */
  /* The rail is light, like the rest of the surface — the mark is black
     artwork, and the selected item is what carries the dark weight. */
  .side {
    background: var(--bg); color: var(--ink);
    border-right: 1px solid var(--line);
    display: flex; flex-direction: column; min-height: 100vh;
    position: sticky; top: 0; height: 100vh; overflow-y: auto;
  }
  .brand {
    display: flex; align-items: center; gap: 10px;
    padding: 16px 18px; border-bottom: 1px solid var(--line);
  }
  .brand .logo { display: block; height: 34px; width: auto; flex: none; }
  .tag {
    margin-left: auto; font: 700 10px/1 var(--mono); letter-spacing: 1px;
    padding: 5px 7px; border: 1px solid var(--line); border-radius: 5px;
    color: var(--ink-soft); background: var(--panel);
  }
  .meta {
    margin: 14px 14px 4px; padding: 12px 14px;
    border: 1px solid var(--line); border-radius: 10px; background: var(--panel);
  }
  .meta div {
    display: flex; justify-content: space-between; gap: 10px;
    font: 11px/2.05 var(--mono); letter-spacing: .4px;
  }
  .meta .k { color: var(--muted); text-transform: uppercase; }
  .meta .v { color: var(--ink); text-align: right; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .navgrp {
    padding: 18px 20px 8px; font: 700 10px/1 var(--mono);
    letter-spacing: 1.4px; color: var(--muted); text-transform: uppercase;
  }
  .nav { padding: 0 10px; }
  .nav button {
    width: 100%; display: flex; align-items: center; gap: 8px;
    background: transparent; border: 0; color: var(--ink); text-align: left;
    padding: 10px 12px; border-radius: 8px; cursor: pointer; font-size: 15px;
  }
  .nav button:hover { background: var(--panel-2); }
  .nav button.on { background: #17150f; color: #fff; font-weight: 600; }
  .nav .count {
    margin-left: auto; font: 700 11px/1 var(--mono);
    background: var(--panel-2); color: var(--muted); padding: 4px 8px; border-radius: 999px;
  }
  .nav button.on .count { background: rgba(255,255,255,.16); color: #fff; }
  .side .foot {
    margin-top: auto; padding: 14px 18px; border-top: 1px solid var(--line);
    display: flex; align-items: center; gap: 10px;
  }
  .avatar {
    width: 32px; height: 32px; border-radius: 50%; background: #17150f;
    display: grid; place-items: center; font: 700 11px/1 var(--mono); color: #fff;
  }
  .foot .who { font-size: 14px; font-weight: 600; color: var(--ink); }
  .foot .role { font: 10px/1.4 var(--mono); letter-spacing: 1px; color: var(--muted); text-transform: uppercase; }

  /* ------------------------------------------------------------- main --- */
  .main { min-width: 0; display: flex; flex-direction: column; }
  .topbar {
    display: flex; align-items: center; gap: 14px; padding: 14px 26px;
    border-bottom: 1px solid var(--line); background: var(--bg);
    position: sticky; top: 0; z-index: 5;
  }
  .crumb { font-size: 14px; color: var(--muted); display: flex; gap: 8px; align-items: center; min-width: 0; }
  .crumb b { color: var(--ink); font-weight: 600; }
  .crumb .sep { color: #b8b0a0; }
  .search {
    margin-left: auto; display: flex; align-items: center; gap: 8px;
    background: var(--panel); border: 1px solid var(--line);
    border-radius: 9px; padding: 7px 11px; min-width: 260px;
  }
  .search input { border: 0; background: transparent; outline: none; width: 100%; font-size: 14px; color: var(--ink); }
  .search input::placeholder { color: #9b9384; }
  .search kbd {
    font: 600 10px/1 var(--mono); color: var(--muted);
    border: 1px solid var(--line); border-radius: 4px; padding: 3px 5px; background: var(--bg);
  }
  .health { display: flex; align-items: center; gap: 7px; font: 11px/1 var(--mono); letter-spacing: .6px; color: var(--muted); }
  .led { width: 8px; height: 8px; border-radius: 50%; background: #b8b0a0; }
  .led.ok { background: #2fa35b; box-shadow: 0 0 0 3px rgba(47,163,91,.16); }
  .led.bad { background: var(--red); box-shadow: 0 0 0 3px rgba(192,57,43,.16); }

  .wrap { padding: 26px; display: flex; flex-direction: column; gap: 18px; max-width: 1500px; }
  .head { display: flex; align-items: flex-start; gap: 16px; flex-wrap: wrap; }
  h1 { margin: 0; font-size: 34px; letter-spacing: -.7px; font-weight: 700; }
  .sub { margin: 6px 0 0; font: 12px/1.5 var(--mono); color: var(--muted); letter-spacing: .2px; }
  .head .acts { margin-left: auto; display: flex; gap: 10px; flex-wrap: wrap; }

  /* ----------------------------------------------------------- atoms --- */
  .btn {
    border: 1px solid var(--line); background: var(--panel); color: var(--ink);
    border-radius: 9px; padding: 9px 14px; cursor: pointer; font-size: 14px; font-weight: 500;
    white-space: nowrap;
  }
  .btn:hover { background: #fff; }
  .btn.primary { background: var(--purple); border-color: var(--purple); color: #fff; font-weight: 600; }
  .btn.primary:hover { background: var(--purple-hi); }
  .btn.dark { background: #17150f; border-color: #17150f; color: #fff; font-weight: 600; }
  .btn.danger { background: transparent; border-color: var(--red); color: var(--red); font-weight: 600; }
  .btn.danger:hover { background: var(--red-sf); }
  .btn:disabled { opacity: .45; cursor: not-allowed; }
  .btn.sm { padding: 6px 11px; font-size: 13px; }

  .pill {
    display: inline-flex; align-items: center; gap: 6px; padding: 4px 9px; border-radius: 6px;
    font: 600 11px/1.4 var(--mono); letter-spacing: .4px; text-transform: uppercase;
  }
  .pill::before { content: "●"; font-size: 8px; }
  .pill.green { background: var(--green-sf); color: var(--green-ink); }
  .pill.amber { background: var(--amber-sf); color: var(--amber-ink); }
  .pill.grey  { background: #e6e1d6; color: var(--muted); }
  .pill.plain::before { content: none; }

  .chip {
    display: inline-block; padding: 4px 9px; border-radius: 6px; background: var(--panel-2);
    border: 1px solid var(--line-soft); font: 12px/1.35 var(--mono); color: var(--ink-soft);
  }

  .banner {
    display: flex; align-items: center; gap: 14px; padding: 16px 18px;
    border-radius: 12px; border: 1px solid var(--purple-ln); background: var(--purple-sf);
  }
  .banner .icon {
    width: 34px; height: 34px; border-radius: 8px; display: grid; place-items: center;
    background: #fff; border: 1px solid var(--purple-ln); font-weight: 700; color: var(--purple);
    flex: none;
  }
  .banner .txt { min-width: 0; }
  .banner .t1 { font-weight: 600; }
  .banner .t2 { font: 12px/1.5 var(--mono); color: var(--ink-soft); margin-top: 2px; }
  .banner .acts { margin-left: auto; display: flex; gap: 9px; flex: none; }
  .banner.amber { border-color: var(--amber-ln); background: var(--amber-sf); }
  .banner.amber .icon { border-color: var(--amber-ln); color: var(--amber-ink); }

  .strip {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(138px, 1fr));
    background: var(--panel); border: 1px solid var(--line); border-radius: 12px; overflow: hidden;
  }
  .cell { padding: 15px 16px; border-right: 1px solid var(--line-soft); min-width: 0; }
  .cell:last-child { border-right: 0; }
  .cell .k { font: 600 10px/1 var(--mono); letter-spacing: 1.2px; color: var(--muted); text-transform: uppercase; }
  .cell .v { font-size: 27px; font-weight: 700; letter-spacing: -.5px; margin-top: 9px; }
  .cell .v small { font-size: 13px; font-weight: 600; color: var(--muted); margin-left: 3px; }
  .cell .n { font: 11px/1.5 var(--mono); color: var(--muted); margin-top: 5px; }
  .cell .v.ok { color: var(--green-ink); }
  .cell .v.bad { color: var(--red); }

  .grid { display: grid; grid-template-columns: 1.55fr 1fr; gap: 18px; align-items: start; }
  @media (max-width: 1080px) { .grid { grid-template-columns: 1fr; } body { grid-template-columns: 1fr; } .side { position: static; height: auto; min-height: 0; } }

  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; overflow: hidden; }
  .card > header {
    display: flex; align-items: center; gap: 12px; padding: 14px 18px;
    border-bottom: 1px solid var(--line-soft);
  }
  .card > header h2 { margin: 0; font-size: 16px; font-weight: 650; }
  .card > header .note { margin-left: auto; font: 11px/1 var(--mono); color: var(--muted); letter-spacing: .4px; }
  .card .body { padding: 4px 0; }
  .card .pad { padding: 18px; }

  table { width: 100%; border-collapse: collapse; }
  th {
    text-align: left; padding: 10px 18px; font: 600 10px/1 var(--mono);
    letter-spacing: 1.1px; color: var(--muted); text-transform: uppercase;
    border-bottom: 1px solid var(--line-soft);
  }
  td { padding: 14px 18px; border-bottom: 1px solid var(--line-soft); vertical-align: middle; }
  tr:last-child td { border-bottom: 0; }
  td.num { font-variant-numeric: tabular-nums; font-family: var(--mono); font-size: 13px; }
  .mono { font-family: var(--mono); font-size: 13px; }
  .t-name { font-weight: 600; }
  .t-sub { font: 12px/1.5 var(--mono); color: var(--muted); margin-top: 3px; }
  .right { text-align: right; }
  .rowacts { display: flex; gap: 8px; justify-content: flex-end; align-items: center; flex-wrap: wrap; }
  .pctin { width: 62px; padding: 6px 8px; border: 1px solid var(--line); border-radius: 8px; background: var(--card); color: var(--ink); font: inherit; font-size: 13px; }

  select, .inp {
    background: #fff; border: 1px solid var(--line); border-radius: 8px;
    padding: 8px 10px; color: var(--ink); font-size: 13.5px; max-width: 100%;
  }
  select { font-family: var(--mono); font-size: 12.5px; }
  .field { display: flex; flex-direction: column; gap: 6px; margin-bottom: 13px; }
  .field label { font: 600 10px/1 var(--mono); letter-spacing: 1.1px; color: var(--muted); text-transform: uppercase; }
  .field .hint { font: 11px/1.5 var(--mono); color: var(--muted); }

  .empty { padding: 34px 18px; text-align: center; color: var(--muted); }
  .empty .big { font-size: 15px; color: var(--ink-soft); margin-bottom: 4px; }
  .empty .small { font: 12px/1.6 var(--mono); }

  .applist { display: flex; flex-direction: column; }
  .applist button {
    display: flex; align-items: center; gap: 10px; width: 100%; text-align: left;
    background: transparent; border: 0; border-bottom: 1px solid var(--line-soft);
    padding: 13px 18px; cursor: pointer; color: var(--ink);
  }
  .applist button:last-child { border-bottom: 0; }
  .applist button:hover { background: var(--panel-2); }
  .applist button.on { background: #fff; box-shadow: inset 3px 0 0 var(--purple); }

  #toast {
    position: fixed; bottom: 22px; left: 50%; transform: translateX(-50%) translateY(8px);
    background: #17150f; color: #fff; padding: 12px 18px; border-radius: 10px;
    opacity: 0; transition: opacity .18s, transform .18s; pointer-events: none;
    max-width: 80vw; font-size: 14px; z-index: 50; box-shadow: 0 8px 26px rgba(0,0,0,.22);
  }
  #toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
  #toast.err { background: var(--red); }
  .hidden { display: none !important; }
</style>
</head>
<body>

<aside class="side">
  <div class="brand">
    <!-- The real mark, served from the binary at /brand/logo.png. -->
    <img class="logo" src="/brand/logo.png" alt="Ejenix" width="118" height="40">
    <span class="tag" id="envTag">LIVE</span>
  </div>

  <div class="meta">
    <div><span class="k">Server</span><span class="v" id="mServer">—</span></div>
    <div><span class="k">App</span><span class="v" id="mApp">none</span></div>
    <div><span class="k">Envs</span><span class="v" id="mEnvs">0</span></div>
    <div><span class="k">Auth</span><span class="v" id="mAuth">no key</span></div>
  </div>

  <div class="navgrp">Overview</div>
  <div class="nav">
    <button data-view="overview" class="on">Command Center<span class="count" id="cOver">0</span></button>
  </div>

  <div class="navgrp">Release operations</div>
  <div class="nav">
    <button data-view="apps">Apps<span class="count" id="cApps">0</span></button>
    <button data-view="envs">Environments<span class="count" id="cEnvs">0</span></button>
    <button data-view="bundles">Bundles<span class="count" id="cBundles">0</span></button>
  </div>

  <div class="navgrp">Governance</div>
  <div class="nav">
    <button data-view="settings">Admin key</button>
  </div>

  <div class="foot">
    <div class="avatar" id="fAv">—</div>
    <div>
      <div class="who" id="fWho">Not signed in</div>
      <div class="role">Control plane</div>
    </div>
  </div>
</aside>

<div class="main">
  <div class="topbar">
    <div class="crumb">
      <span id="bcApp">no app</span><span class="sep">/</span>
      <span id="bcEnv">—</span><span class="sep">/</span>
      <b id="bcView">Command Center</b>
    </div>
    <div class="search">
      <input id="q" type="search" placeholder="Filter apps, bundles, environments…" autocomplete="off">
      <kbd>/</kbd>
    </div>
    <div class="health"><span class="led" id="led"></span><span id="ledTxt">checking</span></div>
  </div>

  <div class="wrap">
    <div class="head">
      <div>
        <h1 id="pageTitle">Command Center</h1>
        <p class="sub" id="pageSub">connect with your admin key to begin</p>
      </div>
      <div class="acts">
        <button class="btn" id="refresh">Refresh</button>
        <button class="btn dark" id="jumpKey">Admin key</button>
      </div>
    </div>

    <div id="banners"></div>
    <div class="strip" id="strip"></div>
    <div id="view"></div>
  </div>
</div>

<div id="toast"></div>

<script>
"use strict";
const $ = s => document.querySelector(s);
const $$ = s => Array.from(document.querySelectorAll(s));

let apps = [], sel = null, envs = [], bundles = [], view = 'overview';
let health = null, activations = 0, uploads = 0, filter = '';

const KEY = 'ejenix_key';
const key = () => localStorage.getItem(KEY) || '';
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const short = id => !id ? '' : String(id).slice(0, 8);

function toast(msg, isErr) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = 'show' + (isErr ? ' err' : '');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { t.className = ''; }, isErr ? 5000 : 2600);
}

async function api(path, opts) {
  opts = Object.assign({}, opts);
  opts.headers = Object.assign({ authorization: 'Bearer ' + key() }, opts.headers || {});
  const r = await fetch(path, opts);
  const text = await r.text();
  let body = {};
  if (text) { try { body = JSON.parse(text); } catch (_) { body = {}; } }
  if (!r.ok) throw new Error(body.error || ('HTTP ' + r.status));
  return body;
}

function bytes(n) {
  if (n == null) return '—';
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  return (n / 1048576).toFixed(2) + ' MB';
}
function ago(ms) {
  if (!ms) return '—';
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return s + 's ago';
  if (s < 3600) return Math.round(s / 60) + 'm ago';
  if (s < 86400) return Math.round(s / 3600) + 'h ago';
  return Math.round(s / 86400) + 'd ago';
}

/* ------------------------------------------------------------ loading --- */

async function loadHealth() {
  try {
    const r = await fetch('/v1/ready');
    const b = await r.json().catch(() => ({}));
    health = r.ok && b.ready !== false;
  } catch (_) { health = false; }
  const led = $('#led');
  led.className = 'led ' + (health ? 'ok' : 'bad');
  $('#ledTxt').textContent = health ? 'healthy' : 'unreachable';
}

// /metrics is Prometheus text; pull the two counters the dashboard shows.
async function loadMetrics() {
  try {
    const text = await (await fetch('/metrics')).text();
    let act = 0, up = 0;
    for (const line of text.split('\n')) {
      if (line.startsWith('#') || !line.trim()) continue;
      const sp = line.lastIndexOf(' ');
      if (sp < 0) continue;
      const name = line.slice(0, sp), val = parseFloat(line.slice(sp + 1));
      if (isNaN(val)) continue;
      if (name.startsWith('ejenix_activations_total')) act += val;
      if (name.startsWith('ejenix_bundle_uploads_total')) up += val;
    }
    activations = act; uploads = up;
  } catch (_) { /* metrics are optional to the page */ }
}

async function loadApps() {
  if (!key()) { apps = []; return; }
  apps = (await api('/v1/apps')).apps || [];
  if (sel) sel = apps.find(a => a.id === sel.id) || null;
  if (!sel && apps.length) sel = apps[0];
}

async function loadDetail() {
  envs = []; bundles = [];
  if (!sel || !key()) return;
  const id = encodeURIComponent(sel.id);
  const [e, b] = await Promise.all([
    api('/v1/apps/' + id + '/envs').then(r => r.environments || []).catch(() => []),
    api('/v1/apps/' + id + '/bundles').then(r => r.bundles || []).catch(() => []),
  ]);
  envs = e; bundles = b;
}

async function refresh(quiet) {
  try {
    await Promise.all([loadHealth(), loadMetrics()]);
    if (key()) { await loadApps(); await loadDetail(); }
  } catch (err) {
    if (!quiet) toast(err.message, true);
  }
  render();
}

/* ---------------------------------------------------------- rendering --- */

const TITLES = {
  overview: 'Command Center',
  apps: 'Apps',
  envs: 'Environments',
  bundles: 'Bundles',
  settings: 'Admin key',
};

function matches(s) { return !filter || String(s).toLowerCase().includes(filter); }

function render() {
  renderChrome();
  renderBanners();
  renderStrip();
  const v = $('#view');
  if (view === 'overview') v.innerHTML = viewOverview();
  else if (view === 'apps') v.innerHTML = viewApps();
  else if (view === 'envs') v.innerHTML = '<div class="grid"><div>' + cardEnvs() + '</div><div>' + cardCreate() + '</div></div>';
  else if (view === 'bundles') v.innerHTML = '<div class="grid"><div>' + cardBundles() + '</div><div>' + cardAppList() + '</div></div>';
  else v.innerHTML = viewSettings();
  wire();
}

function renderChrome() {
  const activeEnvs = envs.filter(e => e.activeBundleId).length;
  $('#mServer').textContent = location.host || '—';
  $('#mApp').textContent = sel ? sel.id : 'none';
  $('#mEnvs').textContent = String(envs.length);
  $('#mAuth').textContent = key() ? 'key set' : 'no key';
  $('#envTag').textContent = health === false ? 'DOWN' : 'LIVE';

  $('#cOver').textContent = String(envs.length ? activeEnvs : 0);
  $('#cApps').textContent = String(apps.length);
  $('#cEnvs').textContent = String(envs.length);
  $('#cBundles').textContent = String(bundles.length);

  $('#bcApp').textContent = sel ? sel.id : 'no app';
  $('#bcEnv').textContent = envs.length ? (envs.length + ' env' + (envs.length === 1 ? '' : 's')) : '—';
  $('#bcView').textContent = TITLES[view];
  $('#pageTitle').textContent = TITLES[view];

  const parts = [];
  parts.push(sel ? sel.id : 'no app selected');
  parts.push(apps.length + ' app' + (apps.length === 1 ? '' : 's'));
  parts.push(bundles.length + ' bundle' + (bundles.length === 1 ? '' : 's'));
  parts.push(health ? 'server healthy' : 'server unreachable');
  $('#pageSub').textContent = parts.join('  ·  ');

  $('#fAv').textContent = key() ? 'OP' : '—';
  $('#fWho').textContent = key() ? 'Operator' : 'Not signed in';

  $$('.nav button').forEach(b => b.classList.toggle('on', b.dataset.view === view));
}

function renderBanners() {
  const out = [];
  if (!key()) {
    out.push(banner('!', 'Admin key required.',
      'Every /v1 call is authenticated. Paste the key printed by deploy.sh or up.sh.',
      '<button class="btn primary" data-go="settings">Enter key</button>'));
  } else if (health === false) {
    out.push(banner('!', 'The control plane is not answering.',
      'GET /v1/ready failed. The container may still be starting, or the store is unavailable.',
      '<button class="btn" data-act="refresh">Retry</button>', true));
  } else {
    const stale = envs.filter(e => !e.activeBundleId);
    if (sel && stale.length) {
      out.push(banner('!', stale.length + ' environment' + (stale.length === 1 ? '' : 's') + ' with no active bundle.',
        stale.map(e => e.name).join(' · ') + ' — devices there fall back to what shipped in the binary.',
        '<button class="btn" data-go="envs">Open environments</button>', true));
    }
    if (sel && !bundles.length) {
      out.push(banner('!', 'No bundles uploaded for ' + esc(sel.id) + '.',
        'Publish one with: ejenix push <bundle> --server ' + esc(location.origin) + ' --app ' + esc(sel.id),
        ''));
    }
  }
  $('#banners').innerHTML = out.join('');
}

function banner(icon, t1, t2, acts, amber) {
  return '<div class="banner' + (amber ? ' amber' : '') + '">' +
    '<div class="icon">' + icon + '</div>' +
    '<div class="txt"><div class="t1">' + t1 + '</div><div class="t2">' + t2 + '</div></div>' +
    (acts ? '<div class="acts">' + acts + '</div>' : '') +
    '</div>';
}

function renderStrip() {
  const totalBytes = bundles.reduce((n, b) => n + (b.sizeBytes || 0), 0);
  const live = envs.filter(e => e.activeBundleId).length;
  const newest = bundles.reduce((m, b) => Math.max(m, b.uploadedAtMillis || 0), 0);
  const cells = [
    cell('Apps', apps.length, apps.length ? 'registered on this plane' : 'none registered yet'),
    cell('Environments', envs.length, live + ' with an active bundle'),
    cell('Bundles', bundles.length, newest ? 'newest ' + ago(newest) : 'none uploaded'),
    cell('Stored', bytes(totalBytes).split(' ')[0],
      'across ' + bundles.length + ' bundle' + (bundles.length === 1 ? '' : 's'),
      bytes(totalBytes).split(' ')[1]),
    cell('Activations', activations, uploads + ' upload' + (uploads === 1 ? '' : 's') + ' total'),
    cell('Health', health === null ? '…' : (health ? 'ready' : 'down'), health ? 'GET /v1/ready 200' : 'GET /v1/ready failed', '', health ? 'ok' : 'bad'),
  ];
  $('#strip').innerHTML = cells.join('');
}

function cell(k, v, note, unit, cls) {
  return '<div class="cell"><div class="k">' + k + '</div>' +
    '<div class="v ' + (cls || '') + '">' + esc(v) + (unit ? '<small>' + esc(unit) + '</small>' : '') + '</div>' +
    '<div class="n">' + esc(note) + '</div></div>';
}

/* -------------------------------------------------------------- views --- */

function viewOverview() {
  return '<div class="grid"><div>' + cardEnvs() + '</div>' +
    '<div style="display:flex;flex-direction:column;gap:18px">' + cardAppList() + cardBundles() + '</div></div>';
}

function viewApps() {
  return '<div class="grid"><div>' + cardAppList(true) + '</div><div>' + cardCreate() + '</div></div>';
}

function viewSettings() {
  return '<div class="grid"><div class="card"><header><h2>Admin key</h2>' +
    '<span class="note">' + (key() ? 'stored in this browser' : 'not set') + '</span></header>' +
    '<div class="pad">' +
    '<div class="field"><label>Bearer token</label>' +
    '<input class="inp" id="keyIn" type="password" placeholder="admin key" autocomplete="off" value="' + esc(key()) + '">' +
    '<div class="hint">Sent as <code>Authorization: Bearer …</code> on every /v1 call. The server enforces auth; this page holds no privilege of its own.</div>' +
    '</div>' +
    '<div class="rowacts" style="justify-content:flex-start">' +
    '<button class="btn primary" id="keySave">Save key</button>' +
    '<button class="btn danger" id="keyClear">Forget key</button></div>' +
    '</div></div>' +
    '<div class="card"><header><h2>This control plane</h2></header><div class="pad">' +
    '<div class="field"><label>Origin</label><div class="mono">' + esc(location.origin) + '</div></div>' +
    '<div class="field"><label>Readiness</label><div class="mono">' + (health ? 'GET /v1/ready → 200' : 'GET /v1/ready → failed') + '</div></div>' +
    '<div class="field"><label>Publish a bundle</label><div class="hint">ejenix push &lt;bundle&gt; --server ' + esc(location.origin) + ' --app &lt;id&gt; --token &lt;key&gt;</div></div>' +
    '</div></div></div>';
}

/* -------------------------------------------------------------- cards --- */

function cardEnvs() {
  if (!sel) return emptyCard('Environments', 'No app selected', 'Register an app, or pick one from the list.');
  const shown = envs.filter(e => matches(e.name) || matches(e.activeBundleId || ''));
  const opts = bundles.map(b =>
    '<option value="' + esc(b.bundleId) + '">' + esc(short(b.bundleId)) + '… · ' + esc(bytes(b.sizeBytes)) + '</option>').join('');

  const rows = shown.length ? shown.map(e => {
    const has = !!e.activeBundleId;
    // A row is identified by channel AND env: several channels share the env
    // name "production", and keying on the name alone made every Promote
    // button post to the default channel.
    const ch = e.channel || 'default';
    const key = ch + '\u0000' + e.name;
    const pct = (e.rolloutPercent === undefined || e.rolloutPercent === null) ? 100 : e.rolloutPercent;
    const staged = has && pct < 100;
    return '<tr>' +
      '<td><div class="t-name">' + esc(e.name) +
      (ch === 'default' ? '' : ' <span class="chip">' + esc(ch) + '</span>') + '</div>' +
      '<div class="t-sub">' + (e.previousBundleId ? 'prev ' + esc(short(e.previousBundleId)) + '…' : 'no previous bundle') + '</div></td>' +
      '<td>' + (has ? '<span class="chip">' + esc(short(e.activeBundleId)) + '…</span>' : '<span class="t-sub">nothing live</span>') + '</td>' +
      '<td><span class="pill ' + (has ? (staged ? 'amber' : 'green') : 'amber') + '">' +
        (has ? (staged ? pct + '% rollout' : 'live') : 'empty') + '</span></td>' +
      '<td><div class="rowacts">' +
      (bundles.length
        ? '<select data-envsel="' + esc(key) + '">' + opts + '</select>' +
          '<input class="pctin" type="number" min="0" max="100" value="' + pct + '" title="Rollout %" data-envpct="' + esc(key) + '">' +
          '<button class="btn primary sm" data-promote="' + esc(key) + '">Promote</button>'
        : '<span class="t-sub">upload a bundle first</span>') +
      (e.previousBundleId ? '<button class="btn danger sm" data-rollback="' + esc(key) + '">Roll back</button>' : '') +
      '</div></td></tr>';
  }).join('') : '<tr><td colspan="4"><div class="empty"><div class="big">' +
    (envs.length ? 'No environment matches the filter.' : 'No environments yet.') + '</div>' +
    '<div class="small">An environment appears the first time you promote a bundle into it.</div></div></td></tr>';

  return '<div class="card"><header><h2>Environments</h2>' +
    '<span class="note">' + envs.filter(e => e.activeBundleId).length + ' live · ' + envs.length + ' total</span></header>' +
    '<div class="body"><table><thead><tr><th>Environment</th><th>Active bundle</th><th>State</th><th class="right">Action</th></tr></thead>' +
    '<tbody>' + rows + '</tbody></table></div></div>';
}

function cardBundles() {
  if (!sel) return emptyCard('Bundles', 'No app selected', 'Pick an app to see its bundles.');
  const shown = bundles.filter(b => matches(b.bundleId));
  const liveIds = new Set(envs.map(e => e.activeBundleId).filter(Boolean));
  const rows = shown.length ? shown.map(b =>
    '<tr><td><span class="chip">' + esc(short(b.bundleId)) + '…</span>' +
    (liveIds.has(b.bundleId) ? ' <span class="pill green">live</span>' : '') + '</td>' +
    '<td class="num">' + esc(bytes(b.sizeBytes)) + '</td>' +
    '<td class="num">' + esc(ago(b.uploadedAtMillis)) + '</td></tr>').join('')
    : '<tr><td colspan="3"><div class="empty"><div class="big">' +
      (bundles.length ? 'No bundle matches the filter.' : 'No bundles uploaded.') + '</div>' +
      '<div class="small">ejenix push &lt;bundle&gt; --server ' + esc(location.origin) + '</div></div></td></tr>';

  return '<div class="card"><header><h2>Bundles</h2><span class="note">' + bundles.length + ' stored</span></header>' +
    '<div class="body"><table><thead><tr><th>Bundle</th><th>Size</th><th>Uploaded</th></tr></thead>' +
    '<tbody>' + rows + '</tbody></table></div></div>';
}

function cardAppList(full) {
  const shown = apps.filter(a => matches(a.id) || matches(a.name || ''));
  if (!key()) return emptyCard('Apps', 'No admin key', 'Enter your key to list apps.');
  const rows = shown.length ? shown.map(a =>
    '<button data-app="' + esc(a.id) + '" class="' + (sel && sel.id === a.id ? 'on' : '') + '">' +
    '<div style="min-width:0"><div class="t-name">' + esc(a.id) + '</div>' +
    '<div class="t-sub">' + esc(a.name && a.name !== a.id ? a.name : (a.trustedKeys || []).length + ' trusted key(s)') + '</div></div>' +
    (sel && sel.id === a.id ? '<span class="pill green plain" style="margin-left:auto">selected</span>' : '') +
    '</button>').join('')
    : '<div class="empty"><div class="big">' + (apps.length ? 'No app matches the filter.' : 'No apps registered.') + '</div>' +
      '<div class="small">' + (full ? 'Create one with the form beside this list.' : 'Open Apps to register one.') + '</div></div>';

  return '<div class="card"><header><h2>Apps</h2><span class="note">' + apps.length + ' registered</span></header>' +
    '<div class="applist">' + rows + '</div></div>';
}

function cardCreate() {
  return '<div class="card"><header><h2>Register an app</h2></header><div class="pad">' +
    '<div class="field"><label>App id</label><input class="inp" id="naId" placeholder="com.yourco.app"></div>' +
    '<div class="field"><label>Display name</label><input class="inp" id="naName" placeholder="optional"></div>' +
    '<div class="field"><label>Trusted public key</label><input class="inp" id="naKey" placeholder="64 hex characters">' +
    '<div class="hint">The release key devices verify against — the contents of release.key.pub.</div></div>' +
    '<button class="btn primary" id="naCreate">Create app</button>' +
    '</div></div>';
}

function emptyCard(title, big, small) {
  return '<div class="card"><header><h2>' + title + '</h2></header>' +
    '<div class="empty"><div class="big">' + esc(big) + '</div><div class="small">' + esc(small) + '</div></div></div>';
}

/* ------------------------------------------------------------ actions --- */

/* A row key is "<channel>\0<env>"; the default channel keeps the old route so
   this page still works against a control plane that predates channels. */
function envPath(key, tail) {
  const i = key.indexOf('\u0000');
  const ch = key.slice(0, i), env = key.slice(i + 1);
  const base = '/v1/apps/' + encodeURIComponent(sel.id);
  const where = ch === 'default'
    ? '/envs/' + encodeURIComponent(env)
    : '/channels/' + encodeURIComponent(ch) + '/envs/' + encodeURIComponent(env);
  return { url: base + where + '/' + tail, ch: ch, env: env };
}

function envLabel(ch, env) { return ch === 'default' ? env : ch + '/' + env; }

async function promote(key) {
  const s = document.querySelector('[data-envsel="' + CSS.escape(key) + '"]');
  const p = document.querySelector('[data-envpct="' + CSS.escape(key) + '"]');
  const id = s && s.value;
  if (!id) { toast('No bundle selected', true); return; }
  const pct = p ? Math.max(0, Math.min(100, parseInt(p.value, 10) || 0)) : 100;
  const t = envPath(key, 'active');
  if (pct < 100 && !confirm('Expose ' + short(id) + '… to ' + pct + '% of devices on ' + envLabel(t.ch, t.env) + '?')) return;
  try {
    await api(t.url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ bundleId: id, rolloutPercent: pct }),
    });
    toast('Promoted ' + short(id) + '… to ' + envLabel(t.ch, t.env) + (pct < 100 ? ' (' + pct + '%)' : ''));
    await refresh(true);
  } catch (e) { toast(e.message, true); }
}

async function rollback(key) {
  const t = envPath(key, 'rollback');
  if (!confirm('Roll ' + envLabel(t.ch, t.env) + ' back to its previous bundle?')) return;
  try {
    await api(t.url, { method: 'POST' });
    toast('Rolled back ' + envLabel(t.ch, t.env));
    await refresh(true);
  } catch (e) { toast(e.message, true); }
}

async function createApp() {
  const id = $('#naId').value.trim(), name = $('#naName').value.trim(), pk = $('#naKey').value.trim();
  if (!id || !pk) { toast('App id and a trusted key are required', true); return; }
  try {
    const r = await api('/v1/apps', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ id: id, name: name || id, trustedKeys: [pk] }),
    });
    toast('Created ' + id + (r.apiKey ? ' — API key: ' + r.apiKey : ''));
    sel = { id: id };
    await refresh(true);
  } catch (e) { toast(e.message, true); }
}

/* -------------------------------------------------------------- wiring --- */

function wire() {
  $$('[data-app]').forEach(b => b.onclick = async () => {
    sel = apps.find(a => a.id === b.dataset.app) || null;
    await loadDetail(); render();
  });
  $$('[data-promote]').forEach(b => b.onclick = () => promote(b.dataset.promote));
  $$('[data-rollback]').forEach(b => b.onclick = () => rollback(b.dataset.rollback));
  $$('[data-go]').forEach(b => b.onclick = () => { view = b.dataset.go; render(); });
  $$('[data-act="refresh"]').forEach(b => b.onclick = () => refresh());
  const c = $('#naCreate'); if (c) c.onclick = createApp;
  const ks = $('#keySave');
  if (ks) ks.onclick = async () => {
    localStorage.setItem(KEY, $('#keyIn').value.trim());
    toast(key() ? 'Key saved' : 'Key cleared');
    await refresh(true);
  };
  const kc = $('#keyClear');
  if (kc) kc.onclick = async () => {
    localStorage.removeItem(KEY); sel = null; apps = []; envs = []; bundles = [];
    toast('Key forgotten'); await refresh(true);
  };
}

$$('.nav button').forEach(b => b.onclick = () => { view = b.dataset.view; render(); });
$('#refresh').onclick = () => refresh();
$('#jumpKey').onclick = () => { view = 'settings'; render(); };
$('#q').oninput = e => { filter = e.target.value.trim().toLowerCase(); render(); };
document.addEventListener('keydown', e => {
  if (e.key === '/' && document.activeElement.tagName !== 'INPUT') { e.preventDefault(); $('#q').focus(); }
});

refresh(true);
setInterval(() => { loadHealth().then(renderChrome); }, 15000);
</script>
</body>
</html>
''';
