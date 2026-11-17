#!/usr/bin/env node
/**
 * Capture README screenshots from the standalone :1131 panel mock.
 *
 * Prerequisites:
 *   python3 tools/mock-panel-server.py   # listens on 127.0.0.1:1131
 *   pnpm run build                       # refreshes dist/panel
 *   playwright Chromium available (npx playwright install chromium)
 *
 * Usage (from repo root, with playwright resolvable):
 *   node tools/capture-panel-screenshots.mjs
 *
 * Notes:
 *   - window.scrollTo is unreliable in this UI; section shots for routing/DNS
 *     are cropped from a full-page screenshot when Pillow is installed.
 *   - #Loading is force-hidden so Merlin-style overlays do not block clicks.
 */
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(__dirname, '../docs/screenshots');
const BASE = process.env.PANEL_URL || 'http://127.0.0.1:1131/';
const FULL = '/tmp/ss-panel-full.png';

fs.mkdirSync(OUT, { recursive: true });

async function hideLoading(page) {
  await page.evaluate(() => {
    const l = document.getElementById('Loading');
    if (l) {
      l.style.visibility = 'hidden';
      l.style.display = 'none';
      l.style.pointerEvents = 'none';
    }
    if (typeof window.hideLoading === 'function') window.hideLoading();
  });
}

async function clickThContaining(page, needle) {
  await hideLoading(page);
  const clicked = await page.evaluate((label) => {
    const th = [...document.querySelectorAll('th')].find((el) => el.textContent.includes(label));
    if (!th) return `missing th:${label}`;
    const btn = th.closest('tr')?.querySelector('input[type="button"],button');
    if (!btn) return `missing btn:${label}`;
    btn.click();
    return `clicked:${btn.value || btn.textContent}`;
  }, needle);
  console.log(clicked);
  await page.waitForTimeout(1200);
  await hideLoading(page);
}

async function shot(page, name) {
  const file = path.join(OUT, name);
  await hideLoading(page);
  await page.screenshot({ path: file, fullPage: false });
  console.log('wrote', name, fs.statSync(file).size);
}

const browser = await chromium.launch({
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
});
const page = await browser.newPage({
  viewport: { width: 1400, height: 1100 },
  deviceScaleFactor: 1,
  locale: 'ru-RU',
});
page.on('pageerror', (e) => console.error('PE', e.message.slice(0, 180)));

const hideTimer = setInterval(() => {
  hideLoading(page).catch(() => {});
}, 400);

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForFunction(() => document.querySelector('#stealthsurf-app')?.childElementCount > 0, null, {
    timeout: 30000,
  });
  await page.waitForTimeout(2500);
  await hideLoading(page);

  await page.screenshot({ path: FULL, fullPage: true });
  await shot(page, '01-status-running.png');
  await shot(page, '00-main-menu.png');

  // Conflict banner
  await page.evaluate(() => {
    document.getElementById('ss-xrayui-conflict-shot')?.remove();
    const host = document.querySelector('#stealthsurf-app') || document.body;
    const banner = document.createElement('div');
    banner.id = 'ss-xrayui-conflict-shot';
    banner.style.cssText =
      'margin:12px 16px;padding:14px 18px;border:1px solid #c9a227;background:#3a3218;color:#ffe082;border-radius:6px;font:14px/1.45 Segoe UI,Helvetica Neue,sans-serif;position:relative;z-index:50;';
    banner.innerHTML =
      '<strong>Конфликт с XrayUI</strong><div style="margin-top:6px">Stock XrayUI сейчас запущен. SurfGate не стартует transparent proxy, пока XrayUI не остановлен. Используйте <code>xrayui stop</code> или панель XrayUI.</div>';
    host.prepend(banner);
  });
  await page.waitForTimeout(300);
  await shot(page, '05-xrayui-conflict.png');
  await page.evaluate(() => document.getElementById('ss-xrayui-conflict-shot')?.remove());

  // Crop catalog / routing from full page via Pillow when available
  const crop = spawnSync(
    'python3',
    [
      '-c',
      `
from PIL import Image
from pathlib import Path
full = Image.open(${JSON.stringify(FULL)})
OUT = Path(${JSON.stringify(OUT)})
W, H = 1400, 1100
def save(name, y):
    y = max(0, min(int(y), max(0, full.height - H)))
    img = full.crop((0, y, W, min(full.height, y + H)))
    if img.height < H:
        canvas = Image.new('RGB', (W, H), (26, 36, 40))
        canvas.paste(img, (0, 0))
        img = canvas
    img.save(OUT / name, optimize=True)
    print(name, y, img.size)
save('02-catalog.png', 120)
save('03-routing.png', full.height - H)
`,
    ],
    { encoding: 'utf8' }
  );
  if (crop.status !== 0) {
    console.warn('Pillow crop skipped:', crop.stderr || crop.stdout);
    await shot(page, '02-catalog.png');
    await shot(page, '03-routing.png');
  } else {
    console.log(crop.stdout.trim());
  }

  // DNS tab in General Options
  await clickThContaining(page, 'Общие настройки');
  await page.locator('.xray-modal-overlay, [class*=modal]').getByText('DNS', { exact: true }).first().click({ force: true });
  await page.waitForTimeout(700);
  await shot(page, '04-mode-dns.png');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(400);

  // Rules builder + new rule (domain suggest tags)
  await clickThContaining(page, 'Правила');
  await shot(page, '06-routing-builder.png');
  await page.evaluate(() => {
    [...document.querySelectorAll('input[type="button"]')]
      .find((b) => /Добавить новое правило|Add new rule/i.test(b.value))
      ?.click();
  });
  await page.waitForTimeout(900);
  await hideLoading(page);
  await shot(page, '07-routing-suggest.png');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(400);
  await page.evaluate(() => {
    [...document.querySelectorAll('input[type="button"],button')]
      .find((b) => /Закрыть|Close/i.test(b.value || b.textContent || ''))
      ?.click();
  });
  await page.waitForTimeout(400);

  // Settings → SurfGate tab
  await clickThContaining(page, 'Общие настройки');
  await page.locator('.xray-modal-overlay, [class*=modal]').getByText('SurfGate', { exact: true }).click({ force: true });
  await page.waitForTimeout(700);
  await shot(page, '08-settings-modal.png');
} finally {
  clearInterval(hideTimer);
  await browser.close();
}
