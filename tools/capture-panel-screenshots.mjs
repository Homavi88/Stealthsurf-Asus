#!/usr/bin/env node
/**
 * Capture README screenshots from the SurfGate standalone :1131 panel mock.
 *
 * Prerequisites:
 *   python3 tools/mock-panel-server.py   # listens on 127.0.0.1:1131
 *   pnpm run build                       # refreshes dist/panel
 *   pnpm exec playwright install chromium
 *
 * Usage:
 *   node tools/capture-panel-screenshots.mjs
 */
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(__dirname, '../docs/screenshots');
const BASE = process.env.PANEL_URL || 'http://127.0.0.1:1131/';

fs.mkdirSync(OUT, { recursive: true });

async function hideLoading(page) {
  await page.evaluate(() => {
    const l = document.getElementById('Loading');
    if (l) {
      l.style.visibility = 'hidden';
      l.style.display = 'none';
      l.style.pointerEvents = 'none';
    }
    document.getElementById('ss-panel-boot')?.setAttribute('hidden', '');
    if (typeof window.hideLoading === 'function') window.hideLoading();
  });
}

async function shotShell(page, name) {
  await hideLoading(page);
  await page.waitForTimeout(300);
  const file = path.join(OUT, name);
  await page.locator('.ss-panel-shell').first().screenshot({ path: file });
  console.log('wrote', name, fs.statSync(file).size);
}

async function openSettings(page) {
  await hideLoading(page);
  await page.locator('button[aria-label="Настройки"], button[title="Настройки"]').first().click({ force: true });
  await page.waitForSelector('.ss-settings-layout', { timeout: 10000 });
  await page.waitForTimeout(600);
  await hideLoading(page);
}

async function openSection(page, label) {
  await hideLoading(page);
  await page.locator('.ss-nav-item', { hasText: label }).first().click({ force: true });
  await page.waitForTimeout(650);
  await hideLoading(page);
}

const browser = await chromium.launch({
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
});
const page = await browser.newPage({
  viewport: { width: 980, height: 1600 },
  deviceScaleFactor: 1,
  locale: 'ru-RU',
});
page.on('pageerror', (e) => console.error('PE', e.message.slice(0, 180)));

const hideTimer = setInterval(() => {
  hideLoading(page).catch(() => {});
}, 400);

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForSelector('.ss-brand', { timeout: 30000 });
  await page.waitForTimeout(2200);
  await hideLoading(page);

  const brand = (await page.locator('.ss-brand').innerText()).replace(/\s+/g, ' ').trim();
  console.log('brand=', brand);
  if (!/SurfGate/i.test(brand)) {
    throw new Error(`Expected SurfGate brand on home, got: ${brand}`);
  }

  await shotShell(page, '01-status-running.png');
  await shotShell(page, '00-main-menu.png');
  await shotShell(page, '02-catalog.png');

  await page.evaluate(() => {
    document.getElementById('ss-xrayui-conflict-shot')?.remove();
    const host = document.querySelector('.ss-panel-shell');
    const banner = document.createElement('div');
    banner.id = 'ss-xrayui-conflict-shot';
    banner.style.cssText =
      'margin:0 0 14px;padding:14px 16px;border:1px solid #f0c36a;background:#fff8e8;color:#7a5a10;border-radius:14px;font:14px/1.45 Manrope,Segoe UI,Helvetica Neue,sans-serif;position:relative;z-index:50;box-shadow:0 8px 28px rgba(40,70,110,0.08)';
    banner.innerHTML =
      '<strong>Конфликт с XrayUI</strong><div style="margin-top:6px">Stock XrayUI сейчас запущен. SurfGate не стартует transparent proxy, пока XrayUI не остановлен. Используйте <code>xrayui stop</code> или панель XrayUI.</div>';
    host.prepend(banner);
  });
  await shotShell(page, '05-xrayui-conflict.png');
  await page.evaluate(() => document.getElementById('ss-xrayui-conflict-shot')?.remove());

  await page.setViewportSize({ width: 1280, height: 1400 });
  await openSettings(page);

  const sections = [
    { label: 'Подписка / Аккаунт', file: '08-settings-account.png' },
    { label: 'Подключение', file: '09-settings-connection.png' },
    { label: 'Маршрутизация', file: '03-routing.png' },
    { label: 'Сеть и службы', file: '04-mode-dns.png' },
    { label: 'Исходящие', file: '10-settings-outbounds.png' },
    { label: 'Движок / профили', file: '11-settings-engine.png' },
    { label: 'Логи', file: '12-settings-logs.png' },
    { label: 'Клиенты online', file: '13-settings-clients.png' },
    { label: 'Обновления', file: '14-settings-updates.png' },
  ];

  for (const s of sections) {
    await openSection(page, s.label);
    await shotShell(page, s.file);
  }

  // Connection with an expanded gated block (watchdog ON)
  await openSection(page, 'Подключение');
  const watchdog = page.locator('.ss-set-row', { hasText: 'Автоперезапуск' }).locator('.ss-toggle');
  if (await watchdog.count()) {
    const on = await watchdog.getAttribute('aria-checked');
    if (on !== 'true') await watchdog.click({ force: true });
    await page.waitForTimeout(400);
    await shotShell(page, '09b-settings-connection-open.png');
  }

  fs.copyFileSync(path.join(OUT, '08-settings-account.png'), path.join(OUT, '08-settings-modal.png'));
  fs.copyFileSync(path.join(OUT, '03-routing.png'), path.join(OUT, '06-routing-builder.png'));
  fs.copyFileSync(path.join(OUT, '04-mode-dns.png'), path.join(OUT, '07-routing-suggest.png'));
  console.log('aliases ok');
} finally {
  clearInterval(hideTimer);
  await browser.close();
}
