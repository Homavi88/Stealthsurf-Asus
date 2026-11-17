<template>
  <div>
    <header class="ss-topbar">
      <div class="ss-brand">
        <span class="ss-brand-mark" aria-hidden="true"></span>
        <span>SurfGate</span>
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
      <div class="ss-hero-orb" :class="{ 'is-off': !running }" aria-hidden="true"></div>
      <h1 class="ss-status-title" :class="{ 'is-off': !running }">{{ running ? 'Подключено' : 'Отключено' }}</h1>
      <div class="ss-ip-pill" v-if="displayIp">
        <span aria-hidden="true">🌐</span>
        <span>{{ displayIp }}</span>
      </div>
    </section>

    <div class="ss-resources">
      <span>ЦП <strong>{{ live.cpu_pct }}%</strong></span>
      <span>ОЗУ <strong>{{ memLabel }}</strong></span>
      <span>SurfGate <strong>{{ live.app_rss_mb }} МБ</strong></span>
    </div>

    <div class="ss-card">
      <p class="ss-card-title">Скорость</p>
      <div class="ss-speed-grid">
        <div class="ss-speed-col">
          <h4>VPN</h4>
          <div class="ss-speed-row">↓ <b>{{ fmtRate(rates.vpnDown) }}</b></div>
          <div class="ss-speed-row">↑ <b>{{ fmtRate(rates.vpnUp) }}</b></div>
          <div class="ss-speed-row">Σ <b>{{ fmtBytes(vol.vpn) }}</b></div>
        </div>
        <div class="ss-speed-col">
          <h4>Напрямую</h4>
          <div class="ss-speed-row">↓ <b>{{ fmtRate(rates.directDown) }}</b></div>
          <div class="ss-speed-row">↑ <b>{{ fmtRate(rates.directUp) }}</b></div>
          <div class="ss-speed-row">Σ <b>{{ fmtBytes(vol.direct) }}</b></div>
        </div>
      </div>
    </div>

    <div class="ss-card">
      <div style="display: flex; justify-content: space-between; align-items: center">
        <p class="ss-card-title" style="margin: 0">Локации</p>
        <button type="button" class="ss-icon-btn" style="width: 34px; height: 34px; box-shadow: none" title="Обновить" @click="refreshCatalog">
          ↻
        </button>
      </div>
      <div
        v-for="c in locations"
        :key="String(c.id)"
        class="ss-loc-item"
        :class="{ 'is-active': selectedId === c.id }"
        @click="selectedId = c.id"
      >
        <div class="ss-loc-flag">{{ flagFor(c) }}</div>
        <div class="ss-loc-meta">
          <div class="name">{{ c.title || `ss-${c.id}` }}</div>
          <div class="sub">{{ c.protocol || 'vless' }} · {{ c._ss_location_title || c.location || '—' }}</div>
          <div class="online">{{ c.is_online === false ? 'офлайн' : 'сервер онлайн' }}</div>
        </div>
        <div class="ss-loc-vol">
          <div>{{ fmtBytes(volumeFor(c)) }}</div>
          <div v-if="isImported(c)" style="color: var(--ss-green); font-weight: 700">в outbounds</div>
        </div>
      </div>
      <p v-if="!locations.length" style="color: var(--ss-muted); font-size: 13px; margin: 8px 0 0">
        Нет конфигураций. Откройте настройки → Аккаунт и выполните Sync catalog.
      </p>
    </div>

    <div class="ss-card">
      <div class="ss-loc-meta" style="margin-bottom: 12px">
        <div class="name">{{ activeTitle }}</div>
        <div class="sub">Выбранное подключение · Start/Stop ядра Xray</div>
      </div>
      <button
        type="button"
        class="ss-primary-btn"
        :class="running ? 'stop' : 'start'"
        :disabled="busy || conflict"
        @click="toggle"
      >
        {{ busy ? '…' : running ? 'Стоп' : 'Старт' }}
      </button>
      <p v-if="conflict" style="color: var(--ss-danger); font-size: 12px; margin: 10px 0 0">
        Конфликт с XrayUI — остановите stock XrayUI, чтобы запустить SurfGate.
      </p>
    </div>
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, inject, onBeforeUnmount, onMounted, Ref, ref, watch } from 'vue';
  import engine, { EngineResponseConfig, SubmitActions } from '@/modules/Engine';
  import { parseCatalogPayload, SsCatalogConfig } from '@/modules/StealthSurfCatalog';

  type LiveStatus = {
    ok?: boolean;
    running?: boolean;
    cpu_pct: number;
    mem_used_mb: number;
    mem_total_mb: number;
    app_rss_mb: number;
    wan_ip?: string;
    traffic?: { vpn_up: number; vpn_down: number; direct_up: number; direct_down: number };
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
      const live = ref<LiveStatus>({
        cpu_pct: 0,
        mem_used_mb: 0,
        mem_total_mb: 0,
        app_rss_mb: 0
      });
      const rates = ref<Rates>({ vpnUp: 0, vpnDown: 0, directUp: 0, directDown: 0 });
      const vol = ref({ vpn: 0, direct: 0 });
      let prevTraffic: LiveStatus['traffic'] | null = null;
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
          uiResponse.value?.xrayui?.running === true ||
          uiResponse.value?.xray?.xrayui?.running === true
      );

      const displayIp = computed(() => live.value.wan_ip || window.xray?.router?.wan_ip || '');

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
        return tags;
      });

      const isImported = (c: SsCatalogConfig) => importedTags.value.has(`ss-${c.id}`) || importedTags.value.has(String(c.id));

      const activeTitle = computed(() => {
        const cur = locations.value.find((c) => c.id === selectedId.value);
        return cur?.title || (selectedId.value != null ? `ss-${selectedId.value}` : 'Подключение не выбрано');
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
        // Prefer per-config traffic cache when present on the object
        const anyC = c as SsCatalogConfig & { traffic_bytes?: number; bytes?: number };
        if (typeof anyC.traffic_bytes === 'number') return anyC.traffic_bytes;
        if (typeof anyC.bytes === 'number') return anyC.bytes;
        if (isImported(c) && locations.value.filter(isImported).length === 1) return vol.value.vpn;
        return 0;
      };

      const loadCatalog = async () => {
        try {
          const cfg = await engine.getWebData<SsCatalogConfig[] | { data?: SsCatalogConfig[] }>('ss_configs');
          locations.value = parseCatalogPayload(cfg?.data);
          if (selectedId.value == null && locations.value.length) {
            const imported = locations.value.find(isImported);
            selectedId.value = (imported || locations.value[0]).id;
          }
        } catch {
          locations.value = [];
        }
      };

      const refreshCatalog = async () => {
        busy.value = true;
        try {
          await engine.submit(SubmitActions.ssSync, null, 0);
          await engine.delay(800);
          await loadCatalog();
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

          const t = data.traffic || { vpn_up: 0, vpn_down: 0, direct_up: 0, direct_down: 0 };
          const ts = data.ts || Date.now() / 1000;
          if (prevTraffic && prevTs && ts > prevTs) {
            const dt = ts - prevTs;
            rates.value = {
              vpnUp: Math.max(0, (t.vpn_up - prevTraffic.vpn_up) / dt),
              vpnDown: Math.max(0, (t.vpn_down - prevTraffic.vpn_down) / dt),
              directUp: Math.max(0, (t.direct_up - prevTraffic.direct_up) / dt),
              directDown: Math.max(0, (t.direct_down - prevTraffic.direct_down) / dt)
            };
          }
          vol.value = {
            vpn: (t.vpn_up || 0) + (t.vpn_down || 0),
            direct: (t.direct_up || 0) + (t.direct_down || 0)
          };
          prevTraffic = t;
          prevTs = ts;
          live.value = {
            cpu_pct: data.cpu_pct || 0,
            mem_used_mb: data.mem_used_mb || 0,
            mem_total_mb: data.mem_total_mb || 0,
            app_rss_mb: data.app_rss_mb || 0,
            wan_ip: data.wan_ip,
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
        busy.value = true;
        try {
          const action = running.value ? SubmitActions.serverStop : SubmitActions.serverStart;
          await engine.executeWithLoadingProgress(async () => {
            await engine.submit(action);
          });
          await pollLive();
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
        live,
        rates,
        vol,
        running,
        conflict,
        displayIp,
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
