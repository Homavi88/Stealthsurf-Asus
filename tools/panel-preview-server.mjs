#!/usr/bin/env node
/**
 * Local preview for SurfGate panel UI (no router required).
 * Serves dist/panel + mocks /cgi-bin/* and /ext/ssurf/*.
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..', 'dist', 'panel');
const port = Number(process.env.PORT || 1131);

const configs = [
  {
    id: 1,
    title: 'Нидерланды HYSTERIA',
    protocol: 'hysteria',
    is_online: true,
    expires_at: Math.floor(new Date('2027-02-21').getTime() / 1000),
    _ss_location_title: 'Netherlands',
    _ss_location_code: 'NL'
  },
  {
    id: 2,
    title: 'Германия VLESS',
    protocol: 'vless',
    is_online: true,
    _ss_location_title: 'Germany',
    _ss_location_code: 'DE'
  }
];

const balances = {
  fetched_at: Math.floor(Date.now() / 1000),
  keys: [
    {
      ok: true,
      label: 'Основная подписка',
      key_fp: 'abc',
      key_tail: 'deadbeef',
      email: 'homavi@gmail.com',
      balance: 756,
      referral_balance: 0
    }
  ],
  total_balance: 756,
  total_referral: 0,
  currency: 'RUB',
  message: 'preview'
};

const xrayConfig = {
  log: { loglevel: 'warning' },
  inbounds: [],
  outbounds: [{ tag: 'ss-1', protocol: 'vless' }],
  routing: { rules: [{ name: 'stealthsurf-default', outboundTag: 'ss-1' }] },
  dns: {},
  policy: {}
};

const uiResponse = {
  xray: {
    running: true,
    ui_version: '1.4.35',
    clients_check: false,
    github_proxy: ''
  },
  conflict: null
};

const bootstrap = {
  ok: true,
  panel: { version: 'preview' },
  xray: {
    router: {
      name: 'RT-AX88U',
      firmware: 'preview',
      language: 'ru',
      ip: '192.168.50.1',
      features: '',
      devices_online: {},
      devices: {}
    },
    server: { isRunning: true, b4sni_isRunning: false },
    custom_settings: { stealthsurf_version: '1.4.35' },
    ui_version: '1.4.35',
    clients_check: false,
    running: true
  }
};

const status = () => ({
  ok: true,
  running: true,
  desired: true,
  fw_up: true,
  official: false,
  cpu_pct: 5,
  mem_used_mb: 900,
  mem_total_mb: 2048,
  app_rss_mb: 99,
  wan_ip: '5.231.117.209',
  vpn_server: 'nl.hysteria.example',
  traffic: {
    vpn_up: 12_000_000,
    vpn_down: 85_000_000,
    direct_up: 800_000,
    direct_down: 2_200_000,
    session: { vpn_up: 120000, vpn_down: 850000, direct_up: 8000, direct_down: 22000 },
    by_tag: { 'ss-1': { up: 40000, down: 300000 } }
  },
  ts: Date.now() / 1000
});

const webData = {
  'ss_configs': configs,
  'ss_locations': [],
  balances,
  'api_keys': [{ key: 'stlth_abc_xxxxxxxxxxxxdeadbeef', label: 'Основная подписка' }],
  'xray-config': xrayConfig,
  'xray-ui-response': uiResponse,
  'addon-update-status': { current: '1.4.35', latest: '1.4.35', update_available: false },
  'connection-status': { running: true }
};

function send(res, code, body, type = 'application/json') {
  const data = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(code, {
    'Content-Type': type,
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*'
  });
  res.end(data);
}

function mime(file) {
  if (file.endsWith('.html')) return 'text/html; charset=utf-8';
  if (file.endsWith('.js')) return 'application/javascript; charset=utf-8';
  if (file.endsWith('.css')) return 'text/css; charset=utf-8';
  if (file.endsWith('.svg')) return 'image/svg+xml';
  if (file.endsWith('.png')) return 'image/png';
  if (file.endsWith('.md')) return 'text/markdown; charset=utf-8';
  return 'application/octet-stream';
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url || '/', `http://127.0.0.1:${port}`);
  const p = url.pathname;

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
      'Access-Control-Allow-Headers': '*'
    });
    return res.end();
  }

  if (p === '/cgi-bin/bootstrap') return send(res, 200, bootstrap);
  if (p === '/cgi-bin/status') return send(res, 200, status());
  if (p === '/cgi-bin/api' || p.startsWith('/cgi-bin/')) return send(res, 200, { ok: true });

  const extMatch = p.match(/^\/ext\/ssurf\/([a-zA-Z0-9_-]+)\.(cab|json)$/);
  if (extMatch) {
    const name = extMatch[1];
    if (Object.prototype.hasOwnProperty.call(webData, name)) {
      return send(res, 200, webData[name]);
    }
    return send(res, 404, { error: 'not found' });
  }

  let filePath = path.join(root, p === '/' ? 'index.html' : decodeURIComponent(p));
  if (!filePath.startsWith(root)) {
    res.writeHead(403);
    return res.end('forbidden');
  }
  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    filePath = path.join(root, 'index.html');
  }
  try {
    const buf = fs.readFileSync(filePath);
    res.writeHead(200, { 'Content-Type': mime(filePath), 'Cache-Control': 'no-store' });
    res.end(buf);
  } catch {
    res.writeHead(404);
    res.end('not found');
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`SurfGate panel preview http://127.0.0.1:${port}/`);
});
