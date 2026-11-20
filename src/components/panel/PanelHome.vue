<template>
  <div>
    <header class="ss-topbar">
      <div class="ss-brand">
        <span class="ss-brand-mark" aria-hidden="true"></span>
        <span class="ss-brand-name">SurfGate VPN</span>
      </div>
      <button type="button" class="ss-icon-btn" title="Настройки" aria-label="Настройки" @click="$emit('open-settings')">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="12" cy="12" r="3" />
          <path
            d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9c0 .7.4 1.3 1 1.5H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"
          />
        </svg>
      </button>
    </header>

    <section class="ss-hero">
      <div class="ss-hero-hud" :class="{ 'is-off': !running }" aria-hidden="true">
        <span class="ss-hero-hud-ring"></span>
        <span class="ss-hero-hud-core"></span>
      </div>
      <p class="ss-status-title" :class="{ 'is-off': !running }">{{ statusLabel }}</p>
      <div class="ss-ip-pill" v-if="displayIp || displayVpnServer">
        <span v-if="selectedFlag">{{ selectedFlag }}</span>
        <span class="ss-mono" v-if="displayIp">{{ displayIp }}</span>
        <span class="ss-mono ss-ip-sep" v-if="displayIp && displayVpnServer">·</span>
        <span class="ss-mono ss-ip-vpn" v-if="displayVpnServer" title="Адрес VPN-сервера из конфига">{{ displayVpnServer }}</span>
      </div>
    </section>

    <div v-if="updateAvailable" class="ss-update-banner" role="status">
      <div class="ss-update-banner__text">
        <div class="ss-update-banner__title">Доступна новая версия</div>
        <div class="ss-update-banner__meta ss-mono">
          v{{ updateCurrent }} → <strong>v{{ updateLatest }}</strong>
        </div>
      </div>
      <button
        type="button"
        class="ss-primary-btn start ss-update-banner__btn"
        :disabled="busy || updateBusy"
        @click="installUpdate"
      >
        {{ updateBusy ? '…' : 'Установить' }}
      </button>
    </div>

    <p class="ss-metrics-line" aria-label="системные метрики">
      <span>ЦП <strong>{{ live.cpu_pct }}%</strong></span>
      <span class="ss-metrics-sep">·</span>
      <span>ОЗУ <strong>{{ memLabel }}</strong></span>
      <span class="ss-metrics-sep">·</span>
      <span>SurfGate <strong>{{ live.app_rss_mb }} МБ</strong></span>
    </p>

    <div class="ss-card ss-card-flush">
      <div class="ss-home-card">
        <div class="ss-home-card__icon" aria-hidden="true">⇅</div>
        <div class="ss-home-card__body">
          <div class="ss-home-card__title">Скорость</div>
          <div class="ss-speed-grid">
            <div class="ss-speed-col">
              <div class="ss-speed-col__label">VPN</div>
              <div class="ss-speed-col__val"><span>↓</span>{{ fmtRate(rates.vpnDown) }}</div>
              <div class="ss-speed-col__val"><span>↑</span>{{ fmtRate(rates.vpnUp) }}</div>
            </div>
            <div class="ss-speed-col">
              <div class="ss-speed-col__label">Напрямую</div>
              <div class="ss-speed-col__val"><span>↓</span>{{ fmtRate(rates.directDown) }}</div>
              <div class="ss-speed-col__val"><span>↑</span>{{ fmtRate(rates.directUp) }}</div>
            </div>
          </div>
          <div class="ss-home-card__sub" style="margin-top: 8px">
            Накоплено: VPN {{ fmtBytes(vol.vpn) }} · напрямую {{ fmtBytes(vol.direct) }}
          </div>
        </div>
      </div>
    </div>

    <div class="ss-card ss-card-flush">
      <div class="ss-home-card">
        <div class="ss-home-card__icon" aria-hidden="true">{{ selectedFlag || '🛰️' }}</div>
        <div class="ss-home-card__body">
          <div class="ss-home-card__title">{{ activeTitle }}</div>
          <div class="ss-home-card__sub">{{ selectedMeta }}</div>
          <div class="ss-home-card__meta" :class="{ 'is-off': !running || selectedOffline }">
            {{ selectedOnlineLabel }}
          </div>
        </div>
        <div class="ss-home-card__aside">
          <span v-if="selectedProto" class="ss-mono">{{ selectedProto }}</span>
        </div>
      </div>
      <div style="padding: 0 14px 14px">
        <button
          type="button"
          class="ss-primary-btn"
          :class="running ? 'stop' : 'start'"
          :disabled="busy || (!running && (conflict || selectedId == null))"
          @click="toggle"
        >
          {{ busy ? '…' : running ? 'Отключить' : 'Подключить' }}
        </button>
        <p v-if="conflict" class="ss-home-error">{{ conflictHint }}</p>
        <p v-else-if="lastError" class="ss-home-error">{{ lastError }}</p>
        <p v-else-if="!running && startFailedHint" class="ss-home-error">{{ startFailedHint }}</p>
        <p v-else class="ss-home-card__sub" style="margin-top: 10px">{{ homeActionHint }}</p>
      </div>
    </div>

    <div class="ss-card ss-card-flush">
      <div class="ss-card-head">
        <p class="ss-card-title" style="margin: 0">Серверы</p>
        <button type="button" class="ss-icon-btn" style="width: 34px; height: 34px" title="Обновить" @click="refreshCatalog">
          ↻
        </button>
      </div>
      <table class="ss-data-table ss-endpoints-table" aria-label="серверы">
        <tbody>
          <tr
            v-for="c in locations"
            :key="String(c.id)"
            class="ss-row-click"
            :class="{ 'is-active': selectedId === c.id }"
            @click="selectEndpoint(c)"
          >
            <td class="ss-flag-cell">{{ flagFor(c) }}</td>
            <td>
              <div class="ss-cell-title">{{ c.title || `ss-${c.id}` }}</div>
              <div class="ss-cell-sub">{{ c._ss_location_title || c.protocol || '—' }}</div>
              <div v-if="running && isActiveRoute(c)" class="ss-cell-tag">активен</div>
              <div v-else-if="!running && isActiveRoute(c)" class="ss-cell-tag is-muted">в конфиге</div>
              <div v-else-if="isImported(c)" class="ss-cell-tag is-muted">импортирован</div>
            </td>
            <td class="ss-mono">{{ c.protocol || 'vless' }}</td>
            <td :class="c.is_online === false ? 'is-off' : 'is-on'">
              {{ c.is_online === false ? 'офлайн' : 'онлайн' }}
            </td>
            <td class="ss-num ss-mono">{{ fmtBytes(volumeFor(c)) }}</td>
          </tr>
          <tr v-if="!locations.length">
            <td colspan="5" class="ss-empty">Нет конфигов — Настройки → Подписка → API-ключ и синхронизация</td>
          </tr>
        </tbody>
      </table>
    </div>

    <panel-update-progress ref="updateProgress" />
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, inject, onBeforeUnmount, onMounted, Ref, ref, watch } from 'vue';
  import engine, { EngineResponseConfig, SubmitActions } from '@/modules/Engine';
  import { createPoller, Poller } from '@/modules/Polling';
  import { catalogTag, parseCatalogPayload, SsCatalogConfig } from '@/modules/StealthSurfCatalog';
  import PanelUpdateProgress from './PanelUpdateProgress.vue';
  import { savePanelNav } from './panelNav';
  import { checkSurfGateUpdate, compareVersions } from '@/modules/SurfGateUpdate';

  interface UpdateStatus {
    current?: string;
    latest?: string;
    update_available?: boolean;
    checked_at?: string;
    message?: string;
  }

  type TrafficByTag = Record<string, { up?: number; down?: number }>;
  type LiveTraffic = {
    vpn_up: number;
    vpn_down: number;
    direct_up: number;
    direct_down: number;
    session?: { vpn_up: number; vpn_down: number; direct_up: number; direct_down: number };
    by_tag?: TrafficByTag;
  };
  type LiveStatus = {
    ok?: boolean;
    running?: boolean;
    desired?: boolean;
    fw_up?: boolean;
    official?: boolean;
    cpu_pct: number;
    mem_used_mb: number;
    mem_total_mb: number;
    app_rss_mb: number;
    wan_ip?: string;
    vpn_server?: string;
    traffic?: LiveTraffic;
    ts?: number;
  };

  type Rates = { vpnUp: number; vpnDown: number; directUp: number; directDown: number };

  export default defineComponent({
    name: 'PanelHome',
    components: { PanelUpdateProgress },
    emits: ['open-settings'],
    setup() {
      const uiResponse = inject<Ref<EngineResponseConfig>>('uiResponse', ref({} as EngineResponseConfig));
      const locations = ref<SsCatalogConfig[]>([]);
      const selectedId = ref<number | string | null>(null);
      const busy = ref(false);
      const lastError = ref('');
      const activeOutboundTag = ref('');
      const live = ref<LiveStatus>({
        cpu_pct: 0,
        mem_used_mb: 0,
        mem_total_mb: 0,
        app_rss_mb: 0
      });
      const rates = ref<Rates>({ vpnUp: 0, vpnDown: 0, directUp: 0, directDown: 0 });
      const vol = ref({ vpn: 0, direct: 0 });
      const byTag = ref<TrafficByTag>({});
      const updateStatus = ref<UpdateStatus | null>(null);
      const updateBusy = ref(false);
      const updateProgress = ref<{ run: (version?: string) => Promise<void> } | null>(null);
      let prevSession: LiveTraffic['session'] | null = null;
      let prevTs = 0;
      let livePoller: Poller | null = null;

      const running = computed(() => {
        if (typeof live.value.running === 'boolean') return live.value.running;
        if (typeof uiResponse.value?.xray?.running === 'boolean') return uiResponse.value.xray.running;
        return Boolean(window.xray?.server?.isRunning);
      });

      const conflict = computed(
        () =>
          live.value.official === true ||
          uiResponse.value?.conflict === 'xrayui' ||
          uiResponse.value?.conflict === 'official' ||
          uiResponse.value?.xrayui?.running === true ||
          uiResponse.value?.xray?.xrayui?.running === true ||
          uiResponse.value?.official?.running === true ||
          uiResponse.value?.xray?.official?.running === true
      );
      const conflictHint = computed(() => {
        if (live.value.official || uiResponse.value?.conflict === 'official' || uiResponse.value?.official?.running) {
          return 'Конфликт: официальный StealthSurf запущен — сначала остановите его';
        }
        return 'Конфликт: XrayUI запущен — сначала остановите его';
      });
      const statusLabel = computed(() => {
        if (live.value.official && !running.value) return 'Отключено · official StealthSurf';
        if (running.value) return 'Подключено';
        if (live.value.desired && !running.value) {
          return 'Отключено · нажмите «Подключить»';
        }
        return 'Отключено';
      });

      const homeActionHint = computed(() => {
        if (running.value) return 'VPN работает — «Отключить» остановит сервис';
        if (conflict.value) return 'Конфликт с другим VPN — остановите его сначала';
        if (selectedId.value == null) return 'Выберите сервер — «Подключить» импортирует и запустит';
        return 'VPN выключен — «Подключить» запустит выбранный сервер';
      });

      const startFailedHint = computed(() => {
        if (running.value || !lastError.value) return '';
        return lastError.value;
      });

      const displayIp = computed(() => live.value.wan_ip || window.xray?.router?.wan_ip || '');
      const displayVpnServer = computed(() => {
        if (!running.value) return '';
        return (live.value.vpn_server || '').trim();
      });

      const clientLatest = ref('');
      const clientUpdate = ref(false);

      const updateLatest = computed(() => clientLatest.value || updateStatus.value?.latest || '');
      const updateCurrent = computed(
        () =>
          window.xray?.custom_settings?.stealthsurf_version ||
          uiResponse.value?.xray?.ui_version ||
          updateStatus.value?.current ||
          '—'
      );
      // Always compare versions — stale addon-update-status can keep update_available=true
      // after install (e.g. banner shows v1.4.27 → v1.4.27).
      const updateAvailable = computed(() => {
        const latest = String(updateLatest.value || '').replace(/^v/i, '');
        const current = String(updateCurrent.value || '').replace(/^v/i, '');
        if (!latest || !current || current === '—') return false;
        if (clientUpdate.value && compareVersions(latest, current) === 1) return true;
        if (updateStatus.value?.update_available && compareVersions(latest, current) === 1) return true;
        return compareVersions(latest, current) === 1;
      });

      const loadUpdateStatus = async () => {
        try {
          const res = await engine.getWebData<UpdateStatus>('addon-update-status');
          updateStatus.value = res.data || null;
        } catch {
          /* keep previous */
        }
      };

      const checkClientUpdate = async () => {
        try {
          const info = await checkSurfGateUpdate(
            uiResponse.value?.xray?.ui_version,
            uiResponse.value?.xray?.github_proxy
          );
          clientLatest.value = info.latest;
          clientUpdate.value = info.updateAvailable;
          if (info.latest) window.xray.server.stealthsurf_version_latest = info.latest;
        } catch {
          /* optional */
        }
      };

      const refreshUpdateStatus = async () => {
        await checkClientUpdate();
        try {
          await engine.submit(SubmitActions.addonUpdateCheck);
          await loadUpdateStatus();
        } catch {
          /* optional background check */
        }
        await checkClientUpdate();
      };

      const installUpdate = async () => {
        const version = updateLatest.value;
        if (!version || updateBusy.value) return;
        if (!window.confirm(`Установить SurfGate v${version} с GitHub?`)) return;
        updateBusy.value = true;
        savePanelNav({ view: 'home' });
        try {
          await updateProgress.value?.run(version);
          await loadUpdateStatus();
          await checkClientUpdate();
        } finally {
          updateBusy.value = false;
        }
      };

      const memLabel = computed(() => {
        const u = (live.value.mem_used_mb / 1024).toFixed(1).replace('.', ',');
        const t = (live.value.mem_total_mb / 1024).toFixed(1).replace('.', ',');
        if (!live.value.mem_total_mb) return '—';
        return `${u}/${t} ГБ`;
      });

      const importedTags = computed(() => {
        const tags = new Set<string>();
        (engine.xrayConfig?.outbounds || []).forEach((o) => {
          if (o.tag?.startsWith('ss-')) tags.add(o.tag);
        });
        if (activeOutboundTag.value) tags.add(activeOutboundTag.value);
        return tags;
      });

      const isImported = (c: SsCatalogConfig) => {
        const tag = catalogTag(c);
        return importedTags.value.has(tag) || importedTags.value.has(`ss-${c.id}`);
      };

      const isActiveRoute = (c: SsCatalogConfig) => {
        const tag = catalogTag(c);
        return Boolean(activeOutboundTag.value) && (activeOutboundTag.value === tag || activeOutboundTag.value === `ss-${c.id}`);
      };

      const selectedConfig = computed(() => locations.value.find((c) => c.id === selectedId.value) || null);

      const activeTitle = computed(() => {
        const cur = selectedConfig.value;
        return cur?.title || (selectedId.value != null ? `ss-${selectedId.value}` : 'Сервер не выбран');
      });

      const selectedFlag = computed(() => (selectedConfig.value ? flagFor(selectedConfig.value) : ''));
      const selectedProto = computed(() => {
        const p = selectedConfig.value?.protocol;
        return p ? String(p).toUpperCase() : '';
      });
      const selectedOffline = computed(() => selectedConfig.value?.is_online === false);
      const selectedOnlineLabel = computed(() => {
        if (!selectedConfig.value) return 'выберите сервер из списка';
        if (selectedOffline.value) return 'сервер офлайн';
        return 'сервер онлайн';
      });
      const selectedMeta = computed(() => {
        const c = selectedConfig.value;
        if (!c) return homeActionHint.value;
        const loc = c._ss_location_title || '';
        const exp = c.expires_at ? formatExpiresShort(c.expires_at) : '';
        return [loc, exp].filter(Boolean).join(' · ') || homeActionHint.value;
      });

      const formatExpiresShort = (ts: number) => {
        if (!ts) return '';
        try {
          return `до ${new Date(ts * 1000).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' })}`;
        } catch {
          return '';
        }
      };

      const fmtBytes = (n: number) => {
        if (!n || n < 0) return '0 Б';
        const u = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
        let v = n;
        let i = 0;
        while (v >= 1024 && i < u.length - 1) {
          v /= 1024;
          i++;
        }
        return `${v.toFixed(i === 0 ? 0 : 1)} ${u[i]}`;
      };

      const fmtRate = (bps: number) => {
        if (!bps || bps < 0) return '0 Б/с';
        return `${fmtBytes(bps)}/с`.replace(' Б/с', ' Б/с');
      };

      const flagFor = (c: SsCatalogConfig) => {
        const code = String(c._ss_location_code || '').toUpperCase();
        if (code === 'NL') return '🇳🇱';
        if (code === 'DE') return '🇩🇪';
        if (code === 'US') return '🇺🇸';
        if (code === 'FI') return '🇫🇮';
        return '🛰️';
      };

      const volumeFor = (c: SsCatalogConfig) => {
        const tag = catalogTag(c);
        const row = tag ? byTag.value[tag] : undefined;
        if (row) return (Number(row.up) || 0) + (Number(row.down) || 0);
        const anyC = c as SsCatalogConfig & { traffic_bytes?: number; bytes?: number };
        if (typeof anyC.traffic_bytes === 'number') return anyC.traffic_bytes;
        if (typeof anyC.bytes === 'number') return anyC.bytes;
        return 0;
      };

      const refreshActiveRoute = async () => {
        try {
          const res = await engine.getWebData<{ routing?: { rules?: { name?: string; outboundTag?: string }[] } }>('xray-config');
          const rule = (res.data?.routing?.rules || []).find((r) => r.name === 'stealthsurf-default');
          activeOutboundTag.value = rule?.outboundTag || '';
        } catch {
          activeOutboundTag.value = '';
        }
      };

      const loadCatalog = async () => {
        try {
          const cfg = await engine.getWebData<SsCatalogConfig[] | { data?: SsCatalogConfig[] }>('ss_configs');
          locations.value = parseCatalogPayload(cfg?.data);
          await refreshActiveRoute();
          if (selectedId.value == null && locations.value.length) {
            const active = locations.value.find(isActiveRoute);
            const imported = locations.value.find(isImported);
            selectedId.value = (active || imported || locations.value[0]).id;
          }
        } catch {
          locations.value = [];
        }
      };

      const refreshCatalog = async () => {
        busy.value = true;
        lastError.value = '';
        try {
          await engine.submit(SubmitActions.ssSync, null, 0);
          await engine.delay(800);
          await loadCatalog();
        } catch (e) {
          lastError.value = e instanceof Error ? e.message : 'sync failed';
        } finally {
          busy.value = false;
        }
      };

      /** Import selected API catalog config as default outbound (ss-* tag). */
      const importSelected = async (id: number | string) => {
        await engine.submit(SubmitActions.ssImportConfigs, { ids: [id] }, 1500);
        activeOutboundTag.value = catalogTag(
          locations.value.find((c) => String(c.id) === String(id)) || ({ id } as SsCatalogConfig)
        );
      };

      const selectEndpoint = async (c: SsCatalogConfig) => {
        selectedId.value = c.id;
        lastError.value = '';
        if (!running.value || busy.value || conflict.value) return;
        // VPN already up: switch default route to the picked API config and restart via finalize.
        busy.value = true;
        try {
          await engine.executeWithLoadingProgress(async () => {
            await importSelected(c.id);
          }, false);
          await pollLive();
          await loadCatalog();
        } catch (e) {
          lastError.value = e instanceof Error ? e.message : 'не удалось переключить endpoint';
        } finally {
          busy.value = false;
        }
      };

      const pollLive = async () => {
        try {
          const res = await fetch('/cgi-bin/status', { cache: 'no-store' });
          if (!res.ok) return;
          const data = (await res.json()) as LiveStatus;
          if (!data?.ok && data?.ok !== undefined) return;

          const t = data.traffic || {
            vpn_up: 0,
            vpn_down: 0,
            direct_up: 0,
            direct_down: 0
          };
          const sess = t.session || {
            vpn_up: t.vpn_up || 0,
            vpn_down: t.vpn_down || 0,
            direct_up: t.direct_up || 0,
            direct_down: t.direct_down || 0
          };
          const ts = data.ts || Date.now() / 1000;
          // Rates from session counters (reset on Xray restart); Σ from lifetime totals.
          if (prevSession && prevTs && ts > prevTs) {
            const dt = ts - prevTs;
            const d = (a: number, b: number) => Math.max(0, a - b);
            rates.value = {
              vpnUp: d(sess.vpn_up, prevSession.vpn_up) / dt,
              vpnDown: d(sess.vpn_down, prevSession.vpn_down) / dt,
              directUp: d(sess.direct_up, prevSession.direct_up) / dt,
              directDown: d(sess.direct_down, prevSession.direct_down) / dt
            };
          }
          vol.value = {
            vpn: (t.vpn_up || 0) + (t.vpn_down || 0),
            direct: (t.direct_up || 0) + (t.direct_down || 0)
          };
          byTag.value = t.by_tag || {};
          prevSession = sess;
          prevTs = ts;
          live.value = {
            cpu_pct: data.cpu_pct || 0,
            mem_used_mb: data.mem_used_mb || 0,
            mem_total_mb: data.mem_total_mb || 0,
            app_rss_mb: data.app_rss_mb || 0,
            wan_ip: data.wan_ip,
            vpn_server: data.vpn_server,
            running: data.running,
            desired: data.desired,
            fw_up: data.fw_up,
            official: data.official,
            traffic: t,
            ts
          };
          if (typeof data.running === 'boolean' && window.xray?.server) {
            window.xray.server.isRunning = data.running;
          }
        } catch {
          /* keep last known status — do not force offline on poll errors */
        }
      };

      const toggle = async () => {
        if (conflict.value && !running.value) return;
        lastError.value = '';
        if (!running.value && selectedId.value == null) {
          lastError.value = 'выберите подключение из списка API';
          return;
        }
        const wantRunning = !running.value;
        busy.value = true;
        try {
          if (!wantRunning) {
            await engine.executeWithLoadingProgress(async () => {
              await engine.submit(SubmitActions.serverStop);
            }, false);
          } else {
            const id = selectedId.value as number | string;
            await engine.executeWithLoadingProgress(async () => {
              // API catalog → import as default outbound, then start Xray.
              await importSelected(id);
              await engine.submit(SubmitActions.serverStart);
            }, false);
          }
          // Re-poll a few times — Xray PID / firewall may appear a second after start.
          for (let i = 0; i < 4; i++) {
            await pollLive();
            if (running.value === wantRunning) break;
            await new Promise((r) => setTimeout(r, 800));
          }
          await loadCatalog();
          if (wantRunning && !running.value) {
            lastError.value =
              'Xray не запустился — Settings → Logs или Test Config. Метка «в конфиге» ≠ VPN online.';
          }
        } catch (e) {
          lastError.value =
            e instanceof Error
              ? e.message
              : wantRunning
                ? 'Xray не запустился — откройте Logs / Test Config'
                : 'ошибка stop';
        } finally {
          busy.value = false;
        }
      };

      onMounted(async () => {
        await loadCatalog();
        await loadUpdateStatus();
        // Background GitHub check so the banner appears without opening Updates
        void refreshUpdateStatus();
        // Serial poller: wait for previous /cgi-bin/status before the next tick
        // (setInterval stacked background work and exhausted router RAM).
        livePoller = createPoller(pollLive, 2000);
        livePoller.start();
      });

      onBeforeUnmount(() => {
        livePoller?.stop();
        livePoller = null;
      });

      watch(
        () => uiResponse.value?.xray?.running,
        () => {
          /* keep reactive */
        }
      );

      return {
        locations,
        selectedId,
        busy,
        lastError,
        live,
        rates,
        vol,
        running,
        statusLabel,
        conflict,
        conflictHint,
        homeActionHint,
        startFailedHint,
        selectEndpoint,
        isActiveRoute,
        displayIp,
        displayVpnServer,
        memLabel,
        activeTitle,
        selectedFlag,
        selectedProto,
        selectedOffline,
        selectedOnlineLabel,
        selectedMeta,
        isImported,
        fmtBytes,
        fmtRate,
        flagFor,
        volumeFor,
        refreshCatalog,
        toggle,
        updateAvailable,
        updateLatest,
        updateCurrent,
        updateBusy,
        updateProgress,
        installUpdate
      };
    }
  });
</script>
