<template>
  <div>
    <header class="ss-topbar">
      <div class="ss-brand" aria-hidden="true">
        <span class="ss-brand-mark"></span>
      </div>
      <button type="button" class="ss-icon-btn" title="settings" aria-label="settings" @click="$emit('open-settings')">
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
      <h1 class="ss-brand-hero">SurfGate</h1>
      <p class="ss-brand-hero-sub">merlin · panel :1131 · xray</p>
      <p class="ss-status-title" :class="{ 'is-off': !running }">{{ running ? 'status: online' : 'status: offline' }}</p>
      <div class="ss-ip-pill" v-if="displayIp || displayVpnServer">
        <span class="ss-mono" v-if="displayIp">wan {{ displayIp }}</span>
        <span class="ss-mono ss-ip-sep" v-if="displayIp && displayVpnServer">·</span>
        <span class="ss-mono ss-ip-vpn" v-if="displayVpnServer">vpn {{ displayVpnServer }}</span>
      </div>
    </section>

    <table class="ss-data-table ss-metrics-table ss-mono" aria-label="system metrics">
      <thead>
        <tr>
          <th>cpu</th>
          <th>mem</th>
          <th>rss</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>{{ live.cpu_pct }}%</strong></td>
          <td><strong>{{ memLabel }}</strong></td>
          <td><strong>{{ live.app_rss_mb }} MB</strong></td>
        </tr>
      </tbody>
    </table>

    <div class="ss-card ss-card-flush">
      <p class="ss-card-title">throughput · накоплено</p>
      <table class="ss-data-table ss-mono" aria-label="throughput">
        <thead>
          <tr>
            <th></th>
            <th>rx</th>
            <th>tx</th>
            <th>Σ</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <th scope="row">vpn</th>
            <td>{{ fmtRate(rates.vpnDown) }}</td>
            <td>{{ fmtRate(rates.vpnUp) }}</td>
            <td>{{ fmtBytes(vol.vpn) }}</td>
          </tr>
          <tr>
            <th scope="row">direct</th>
            <td>{{ fmtRate(rates.directDown) }}</td>
            <td>{{ fmtRate(rates.directUp) }}</td>
            <td>{{ fmtBytes(vol.direct) }}</td>
          </tr>
          <tr class="ss-total-row">
            <th scope="row">всего</th>
            <td colspan="2" class="ss-muted">все подключения</td>
            <td>{{ fmtBytes(vol.vpn + vol.direct) }}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="ss-card ss-card-flush">
      <div class="ss-card-head">
        <p class="ss-card-title" style="margin: 0">endpoints</p>
        <button type="button" class="ss-icon-btn" style="width: 34px; height: 34px; box-shadow: none" title="refresh" @click="refreshCatalog">
          ↻
        </button>
      </div>
      <table class="ss-data-table ss-endpoints-table" aria-label="endpoints">
        <thead>
          <tr>
            <th></th>
            <th>endpoint</th>
            <th>proto</th>
            <th>status</th>
            <th class="ss-num">volume</th>
          </tr>
        </thead>
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
              <div class="ss-cell-sub ss-mono">{{ c._ss_location_title || c.location || '—' }}</div>
              <div v-if="isActiveRoute(c)" class="ss-cell-tag">active</div>
              <div v-else-if="isImported(c)" class="ss-cell-tag">imported</div>
            </td>
            <td class="ss-mono">{{ c.protocol || 'vless' }}</td>
            <td class="ss-mono" :class="c.is_online === false ? 'is-off' : 'is-on'">
              {{ c.is_online === false ? 'node off' : 'node ok' }}
            </td>
            <td class="ss-num ss-mono">{{ fmtBytes(volumeFor(c)) }}</td>
          </tr>
          <tr v-if="!locations.length">
            <td colspan="5" class="ss-empty">нет конфигов — настройки → аккаунт → API-ключ и sync</td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="ss-card">
      <div class="ss-loc-meta" style="margin-bottom: 12px">
        <div class="name">{{ activeTitle }}</div>
        <div class="sub ss-mono">{{ running ? 'активен · stop остановит VPN' : 'выберите endpoint · start импортирует и запустит' }}</div>
      </div>
      <button
        type="button"
        class="ss-primary-btn"
        :class="running ? 'stop' : 'start'"
        :disabled="busy || (!running && (conflict || selectedId == null))"
        @click="toggle"
      >
        {{ busy ? '…' : running ? 'stop' : 'start' }}
      </button>
      <p v-if="conflict" class="ss-mono" style="color: var(--ss-danger); font-size: 12px; margin: 10px 0 0">
        {{ conflictHint }}
      </p>
      <p v-else-if="lastError" class="ss-mono" style="color: var(--ss-danger); font-size: 12px; margin: 10px 0 0">
        {{ lastError }}
      </p>
    </div>
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, inject, onBeforeUnmount, onMounted, Ref, ref, watch } from 'vue';
  import engine, { EngineResponseConfig, SubmitActions } from '@/modules/Engine';
  import { catalogTag, parseCatalogPayload, SsCatalogConfig } from '@/modules/StealthSurfCatalog';

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
      let prevSession: LiveTraffic['session'] | null = null;
      let prevTs = 0;
      let timer: ReturnType<typeof setInterval> | null = null;

      const running = computed(() => {
        if (typeof live.value.running === 'boolean') return live.value.running;
        if (typeof uiResponse.value?.xray?.running === 'boolean') return uiResponse.value.xray.running;
        return Boolean(window.xray?.server?.isRunning);
      });

      const conflict = computed(
        () =>
          uiResponse.value?.conflict === 'xrayui' ||
          uiResponse.value?.conflict === 'official' ||
          uiResponse.value?.xrayui?.running === true ||
          uiResponse.value?.xray?.xrayui?.running === true ||
          uiResponse.value?.official?.running === true ||
          uiResponse.value?.xray?.official?.running === true
      );
      const conflictHint = computed(() => {
        if (uiResponse.value?.conflict === 'official' || uiResponse.value?.official?.running) {
          return 'conflict: official StealthSurf is running — stop it first';
        }
        return 'conflict: stock xrayui is running — stop it first';
      });

      const displayIp = computed(() => live.value.wan_ip || window.xray?.router?.wan_ip || '');
      const displayVpnServer = computed(() => {
        if (!running.value) return '';
        return (live.value.vpn_server || '').trim();
      });

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

      const activeTitle = computed(() => {
        const cur = locations.value.find((c) => c.id === selectedId.value);
        return cur?.title || (selectedId.value != null ? `ss-${selectedId.value}` : 'endpoint не выбран');
      });

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
            traffic: t,
            ts
          };
          if (typeof data.running === 'boolean') {
            window.xray.server.isRunning = data.running;
          }
        } catch {
          /* mock / offline */
        }
      };

      const toggle = async () => {
        if (conflict.value && !running.value) return;
        lastError.value = '';
        if (!running.value && selectedId.value == null) {
          lastError.value = 'выберите подключение из списка API';
          return;
        }
        busy.value = true;
        try {
          if (running.value) {
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
          await pollLive();
          await loadCatalog();
        } catch (e) {
          lastError.value = e instanceof Error ? e.message : 'ошибка start/stop';
        } finally {
          busy.value = false;
        }
      };

      onMounted(async () => {
        await loadCatalog();
        await pollLive();
        timer = setInterval(() => {
          void pollLive();
        }, 2000);
      });

      onBeforeUnmount(() => {
        if (timer) clearInterval(timer);
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
        conflict,
        conflictHint,
        selectEndpoint,
        isActiveRoute,
        displayIp,
        displayVpnServer,
        memLabel,
        activeTitle,
        isImported,
        fmtBytes,
        fmtRate,
        flagFor,
        volumeFor,
        refreshCatalog,
        toggle
      };
    }
  });
</script>
