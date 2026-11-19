<template>
  <div class="ss-conn">
    <div v-if="xrayuiConflict" class="ss-alert" role="alert">
      <strong>{{ $t('com.ClientStatus.xrayui_conflict_title') }}</strong>
      <div>{{ conflictMessage }}</div>
    </div>

    <p class="ss-section-label">Статус</p>
    <div class="ss-set-card">
      <div class="ss-set-row has-divider">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">Xray {{ isRunning ? 'запущен' : 'остановлен' }}</div>
            <div class="ss-set-row-sub">{{ uptimeLabel }} · {{ profileLabel }}</div>
          </div>
          <div class="ss-set-row-control ss-set-actions">
            <button type="button" class="ss-chip-btn" :disabled="busy || xrayuiConflict" @click="handleStatus(isRunning ? reconnect : connect)">
              {{ isRunning ? 'Перезапуск' : 'Старт' }}
            </button>
            <button v-if="isRunning" type="button" class="ss-chip-btn danger" :disabled="busy" @click="handleStatus(stop)">Стоп</button>
          </div>
        </div>
      </div>
    </div>

    <p class="ss-section-label">Подключение</p>
    <div class="ss-set-card">
      <ss-settings-row
        title="Запуск при загрузке роутера"
        subtitle="Автоматически стартовать Xray после перезагрузки"
        :toggle="!!options.startup"
        @update:toggle="onStartupToggle"
      >
        <template #detail>
          <label class="ss-field">
            <span>Задержка старта, сек</span>
            <input type="number" min="0" max="9999" v-model.number="options.startup_delay" />
          </label>
        </template>
      </ss-settings-row>

      <ss-settings-row
        title="Автоперезапуск при остановке"
        subtitle="Watchdog перезапустит Xray, если процесс упал"
        :toggle="!!options.watchdog"
        @update:toggle="(v) => (options.watchdog = v)"
      >
        <template #detail>
          <label class="ss-field">
            <span>Интервал проверки</span>
            <select v-model.number="options.watchdog_interval">
              <option :value="1">1 мин</option>
              <option :value="2">2 мин</option>
              <option :value="5">5 мин</option>
              <option :value="10">10 мин</option>
            </select>
          </label>
          <label class="ss-field">
            <span>Макс. попыток</span>
            <input type="number" min="0" max="999" v-model.number="options.watchdog_max_attempts" />
          </label>
        </template>
      </ss-settings-row>

      <ss-settings-row
        v-if="canCheckConnection"
        title="Проверять соединение с сервером"
        subtitle="Периодический probe выбранного outbound"
        :toggle="!!options.check_connection"
        @update:toggle="(v) => (options.check_connection = v)"
      >
        <template #detail>
          <label class="ss-field">
            <span>URL проверки</span>
            <input type="text" v-model="options.probe_url" autocomplete="off" />
          </label>
          <label class="ss-field">
            <span>Интервал, сек</span>
            <input type="number" min="5" max="3600" v-model.number="options.probe_interval" />
          </label>
        </template>
      </ss-settings-row>

      <ss-settings-row
        title="Блокировать QUIC"
        subtitle="UDP 443 — меньше утечек IP через HTTP/3"
        :toggle="!!options.block_quic"
        @update:toggle="(v) => (options.block_quic = v)"
      />

      <ss-settings-row
        title="Kill-switch"
        subtitle="Пока VPN должен работать — без марки SurfGate LAN→WAN блокируется"
        :toggle="!!options.kill_switch"
        :divider="false"
        @update:toggle="(v) => (options.kill_switch = v)"
      />
    </div>

    <p class="ss-section-label">Устройства VPN</p>
    <div class="ss-set-card">
      <div class="ss-set-row has-divider">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">Кому включать VPN</div>
            <div class="ss-set-row-sub">{{ lanModeSubtitle }}</div>
          </div>
        </div>
        <div class="ss-set-row-detail">
          <label class="ss-field">
            <span>Режим</span>
            <select v-model="options.lan_vpn_mode">
              <option value="all">Все устройства</option>
              <option value="selected">Только выбранные</option>
              <option value="exclude">Все, кроме выбранных</option>
            </select>
          </label>
          <label v-if="options.lan_vpn_mode !== 'all'" class="ss-field">
            <span>MAC (через запятую)</span>
            <input type="text" v-model="options.lan_vpn_macs" placeholder="aa:bb:cc:dd:ee:ff, …" autocomplete="off" />
          </label>
        </div>
      </div>

      <div class="ss-set-row has-divider">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">Гостевая Wi‑Fi</div>
            <div class="ss-set-row-sub">{{ guestModeSubtitle }}</div>
          </div>
        </div>
        <div class="ss-set-row-detail">
          <label class="ss-field">
            <span>Режим</span>
            <select v-model="options.guest_vpn_mode">
              <option value="follow">Как основная сеть</option>
              <option value="vpn">Всегда через VPN</option>
              <option value="direct">Без VPN (direct)</option>
            </select>
          </label>
        </div>
      </div>

      <div class="ss-set-row">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">IPv6</div>
            <div class="ss-set-row-sub">{{ ipv6ModeSubtitle }}</div>
          </div>
        </div>
        <div class="ss-set-row-detail">
          <label class="ss-field">
            <span>Режим</span>
            <select v-model="options.ipv6_mode">
              <option value="proxy">Через VPN</option>
              <option value="block">Блокировать IPv6</option>
              <option value="ignore">Не трогать</option>
            </select>
          </label>
        </div>
      </div>
    </div>

    <p class="ss-section-label">Сеть</p>
    <div class="ss-set-card">
      <div class="ss-set-row has-divider">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">Режим DNS / ipset</div>
            <div class="ss-set-row-sub">off · bypass · redirect</div>
          </div>
        </div>
        <div class="ss-set-row-detail">
          <label class="ss-field">
            <span>ipset</span>
            <select v-model="options.ipsec">
              <option v-for="opt in ipsetOptions" :key="opt" :value="opt">{{ opt }}</option>
            </select>
          </label>
        </div>
      </div>

      <ss-settings-row
        title="DNS только через Xray"
        subtitle="DNS leak lock — блокировать обходной DNS с LAN"
        :toggle="!!options.dns_only"
        @update:toggle="(v) => (options.dns_only = v)"
      />

      <ss-settings-row
        title="Проверка клиентов online"
        subtitle="Опрашивать список клиентов в WebUI"
        :toggle="!!options.clients_check"
        @update:toggle="(v) => (options.clients_check = v)"
      />

      <ss-settings-row
        title="Пропускать тест конфигурации"
        subtitle="Не блокировать Start при ошибках xray -test"
        :toggle="!!options.skip_test"
        :divider="false"
        @update:toggle="(v) => (options.skip_test = v)"
      />
    </div>

    <p class="ss-section-label">Диагностика</p>
    <div class="ss-set-card">
      <div class="ss-set-row has-divider">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">Preflight</div>
            <div class="ss-set-row-sub">{{ preflightSubtitle }}</div>
          </div>
          <div class="ss-set-row-control">
            <button type="button" class="ss-chip-btn" :disabled="busy" @click="runPreflight">Проверить</button>
          </div>
        </div>
      </div>
      <div class="ss-set-row has-divider">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">Тест скорости</div>
            <div class="ss-set-row-sub">{{ speedSubtitle }}</div>
          </div>
          <div class="ss-set-row-control">
            <button type="button" class="ss-chip-btn" :disabled="busy" @click="runSpeedTest">Запустить</button>
          </div>
        </div>
      </div>
      <div class="ss-set-row">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">DNS leak</div>
            <div class="ss-set-row-sub">{{ dnsTestSubtitle }}</div>
          </div>
          <div class="ss-set-row-control">
            <button type="button" class="ss-chip-btn" :disabled="busy" @click="runDnsTest">Проверить</button>
          </div>
        </div>
      </div>
    </div>

    <p class="ss-section-label">Каталог и подписки</p>
    <div class="ss-set-card">
      <ss-settings-row
        title="Автосинхронизация каталога"
        :subtitle="catalogSyncSubtitle"
        :toggle="catalogSyncEnabled"
        @update:toggle="setCatalogSync"
      >
        <template #detail>
          <label class="ss-field">
            <span>Интервал</span>
            <select v-model="catalogInterval">
              <option value="15m">15 мин</option>
              <option value="30m">30 мин</option>
              <option value="1h">1 час</option>
              <option value="3h">3 часа</option>
              <option value="6h">6 часов</option>
              <option value="12h">12 часов</option>
            </select>
          </label>
        </template>
      </ss-settings-row>

      <ss-settings-row
        title="Авто-переключение подписок"
        subtitle="Если текущий эндпоинт недоступен — взять следующий"
        :toggle="!!options.subscription_auto_fallback"
        @update:toggle="(v) => (options.subscription_auto_fallback = v)"
      >
        <template #detail>
          <label class="ss-field">
            <span>Интервал проверки, мин</span>
            <input type="number" min="1" max="120" v-model.number="options.subscription_fallback_interval" />
          </label>
        </template>
      </ss-settings-row>

      <ss-settings-row
        title="Автообновление geodata"
        subtitle="Периодически обновлять geoip / geosite"
        :toggle="!!options.geo_auto_update"
        :divider="false"
        @update:toggle="(v) => (options.geo_auto_update = v)"
      />
    </div>

    <div class="ss-conn-footer">
      <button type="button" class="ss-primary-btn start" :disabled="busy" @click="save">Сохранить</button>
    </div>
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, inject, onBeforeUnmount, onMounted, PropType, Ref, ref, watch } from 'vue';
  import { useI18n } from 'vue-i18n';
  import engine, { EngineResponseConfig, SubmitActions } from '@/modules/Engine';
  import { XrayObject } from '@/modules/XrayConfig';
  import { XrayProtocol } from '@/modules/Options';
  import useGeneralOptions from '@modal/GeneralOptionsModal';
  import SsSettingsRow from './SsSettingsRow.vue';

  export default defineComponent({
    name: 'PanelConnection',
    components: { SsSettingsRow },
    props: {
      config: { type: Object as PropType<XrayObject>, required: true }
    },
    setup(props) {
      const { t } = useI18n();
      const uiResponse = inject<Ref<EngineResponseConfig>>('uiResponse')!;
      const { options, ipset_options: ipsetOptions, hydrate, persist } = useGeneralOptions(props.config, uiResponse);
      const busy = ref(false);

      // Prefer live Home poll (`window.xray.server.isRunning`) over stale uiResponse.
      const liveTick = ref(0);
      let liveTimer: ReturnType<typeof setInterval> | null = null;
      const isRunning = computed(() => {
        liveTick.value;
        if (typeof window.xray?.server?.isRunning === 'boolean') return window.xray.server.isRunning;
        const running = uiResponse?.value?.xray?.running;
        if (typeof running === 'boolean') return running;
        const uptime = uiResponse?.value?.xray?.uptime;
        return typeof uptime === 'number' && uptime > 0;
      });

      const xrayuiConflict = computed(
        () =>
          uiResponse?.value?.conflict === 'xrayui' ||
          uiResponse?.value?.xrayui?.running === true ||
          uiResponse?.value?.xray?.xrayui?.running === true
      );
      const conflictMessage = computed(
        () =>
          uiResponse?.value?.conflict_message ||
          uiResponse?.value?.xrayui?.message ||
          uiResponse?.value?.xray?.xrayui?.message ||
          t('com.ClientStatus.xrayui_conflict_message')
      );

      const uptimeLabel = computed(() => {
        const u = uiResponse?.value?.xray?.uptime;
        if (typeof u !== 'number' || u <= 0) return isRunning.value ? 'работает' : 'не запущен';
        const d = Math.floor(u / 86400);
        const h = Math.floor((u % 86400) / 3600);
        const m = Math.floor((u % 3600) / 60);
        const s = Math.floor(u % 60);
        return `${d}д ${h}ч ${m}м ${s}с`;
      });
      const profileLabel = computed(() => uiResponse?.value?.xray?.profile || 'config.json');

      const canCheckConnection = computed(() =>
        !!props.config.outbounds?.find((o) => o.protocol !== XrayProtocol.FREEDOM && o.protocol !== XrayProtocol.BLACKHOLE)
      );

      const catalogInterval = ref('1h');
      const catalogSyncEnabled = computed(() => options.ss_catalog_auto_sync !== 'disabled' && !!options.ss_catalog_auto_sync);
      const catalogSyncSubtitle = computed(() =>
        catalogSyncEnabled.value ? `Интервал: ${options.ss_catalog_auto_sync}` : 'Сейчас каталог обновляется только вручную'
      );

      const lanModeSubtitle = computed(() => {
        switch (options.lan_vpn_mode) {
          case 'selected':
            return 'VPN только для указанных MAC';
          case 'exclude':
            return 'VPN для всех, кроме указанных MAC';
          default:
            return 'Весь LAN через transparent proxy';
        }
      });
      const guestModeSubtitle = computed(() => {
        switch (options.guest_vpn_mode) {
          case 'direct':
            return 'Гостевые мосты br1/br2… без VPN';
          case 'vpn':
            return 'Гостевая сеть всегда через VPN';
          default:
            return 'Те же правила, что у основной LAN';
        }
      });
      const ipv6ModeSubtitle = computed(() => {
        switch (options.ipv6_mode) {
          case 'block':
            return 'Резать IPv6 на WAN (нет утечки мимо VPN)';
          case 'ignore':
            return 'SurfGate не трогает IPv6';
          default:
            return 'IPv6 участвует в transparent proxy';
        }
      });

      const preflight = ref<{ ok?: boolean; message?: string; checked_at?: string } | null>(null);
      const preflightSubtitle = computed(() => {
        if (!preflight.value) return 'NTP · WAN · TPROXY · Xray · конфликт XrayUI';
        const mark = preflight.value.ok ? 'OK' : 'Проблемы';
        return `${mark}: ${preflight.value.message || '—'}`;
      });
      type SpeedStatus = {
        ok?: boolean;
        message?: string;
        checked_at?: string;
        download_mbps?: number | null;
        upload_mbps?: number | null;
        latency_ms?: number | null;
      };
      const speedStatus = ref<SpeedStatus | null>(null);
      const speedSubtitle = computed(() => {
        if (!speedStatus.value) return 'Download / upload через Cloudflare · latency';
        const mark = speedStatus.value.ok ? 'OK' : 'Ошибка';
        return `${mark}: ${speedStatus.value.message || '—'}`;
      });
      type DnsTestStatus = {
        ok?: boolean;
        message?: string;
        checked_at?: string;
        leaked?: boolean;
        exit_ip?: string | null;
      };
      const dnsTestStatus = ref<DnsTestStatus | null>(null);
      const dnsTestSubtitle = computed(() => {
        if (!dnsTestStatus.value) return 'Wiring + resolvers · сверка с WAN DNS';
        const mark = dnsTestStatus.value.leaked ? 'Утечка' : dnsTestStatus.value.ok ? 'OK' : 'Проблемы';
        return `${mark}: ${dnsTestStatus.value.message || '—'}`;
      });
      const loadPreflight = async () => {
        try {
          const res = await engine.getWebData<{ ok?: boolean; message?: string; checked_at?: string }>('preflight-status');
          preflight.value = res.data || null;
        } catch {
          preflight.value = null;
        }
      };
      const loadSpeedStatus = async () => {
        try {
          const res = await engine.getWebData<SpeedStatus>('speedtest-status');
          speedStatus.value = res.data || null;
        } catch {
          speedStatus.value = null;
        }
      };
      const loadDnsTestStatus = async () => {
        try {
          const res = await engine.getWebData<DnsTestStatus>('dnstest-status');
          dnsTestStatus.value = res.data || null;
        } catch {
          dnsTestStatus.value = null;
        }
      };
      const runPreflight = async () => {
        busy.value = true;
        try {
          await engine.executeWithLoadingProgress(async () => {
            await engine.submit(SubmitActions.preflight);
          }, false);
          await loadPreflight();
        } finally {
          busy.value = false;
        }
      };
      const runSpeedTest = async () => {
        busy.value = true;
        try {
          await engine.executeWithLoadingProgress(async () => {
            await engine.submit(SubmitActions.speedTest);
          }, false);
          await loadSpeedStatus();
        } finally {
          busy.value = false;
        }
      };
      const runDnsTest = async () => {
        busy.value = true;
        try {
          await engine.executeWithLoadingProgress(async () => {
            await engine.submit(SubmitActions.dnsTest);
          }, false);
          await loadDnsTestStatus();
        } finally {
          busy.value = false;
        }
      };
      const setCatalogSync = (on: boolean) => {
        if (on) {
          options.ss_catalog_auto_sync = catalogInterval.value || '1h';
        } else {
          if (options.ss_catalog_auto_sync && options.ss_catalog_auto_sync !== 'disabled') {
            catalogInterval.value = options.ss_catalog_auto_sync;
          }
          options.ss_catalog_auto_sync = 'disabled';
        }
      };
      watch(catalogInterval, (v) => {
        if (catalogSyncEnabled.value) options.ss_catalog_auto_sync = v;
      });

      const onStartupToggle = async (on: boolean) => {
        const previous = options.startup;
        options.startup = on;
        // Write absolute value before API call so panel settings land as y/n (no flip race).
        window.xray.custom_settings.stealthsurf_startup = on ? 'y' : 'n';
        busy.value = true;
        try {
          await engine.submit(SubmitActions.setStartupOption);
        } catch {
          options.startup = previous;
          window.xray.custom_settings.stealthsurf_startup = previous ? 'y' : 'n';
        } finally {
          busy.value = false;
        }
      };

      const handleStatus = async (action: string) => {
        if (xrayuiConflict.value && (action === SubmitActions.serverStart || action === SubmitActions.serverRestart)) {
          window.alert(conflictMessage.value);
          return;
        }
        busy.value = true;
        try {
          await engine.executeWithLoadingProgress(async () => {
            await engine.submit(action);
          });
        } finally {
          busy.value = false;
        }
      };

      const save = async () => {
        if (!uiResponse?.value?.xray) {
          window.alert('Настройки ещё загружаются. Подождите и сохраните снова.');
          return;
        }
        busy.value = true;
        try {
          await persist('connection');
          window.xray.custom_settings.stealthsurf_startup = options.startup ? 'y' : 'n';
        } finally {
          busy.value = false;
        }
      };

      const ensureBoolDefaults = () => {
        const o = options as Record<string, unknown>;
        for (const key of [
          'watchdog',
          'check_connection',
          'block_quic',
          'clients_check',
          'skip_test',
          'subscription_auto_fallback',
          'geo_auto_update',
          'debug',
          'kill_switch',
          'dns_only'
        ]) {
          if (typeof o[key] !== 'boolean') o[key] = false;
        }
        // Autostart: missing NVRAM key defaults to on (same as install).
        if (typeof o.startup !== 'boolean') {
          o.startup = window.xray?.custom_settings?.stealthsurf_startup !== 'n';
        }
        if (!options.ipsec) options.ipsec = 'off';
        if (!options.probe_url) options.probe_url = 'https://www.google.com/generate_204';
        if (!options.probe_interval) options.probe_interval = 30;
        if (!options.watchdog_interval) options.watchdog_interval = 2;
        if (options.watchdog_max_attempts == null) options.watchdog_max_attempts = 5;
        if (!options.ss_catalog_auto_sync) options.ss_catalog_auto_sync = 'disabled';
        if (options.ss_catalog_auto_sync !== 'disabled') catalogInterval.value = String(options.ss_catalog_auto_sync);
        if (!options.lan_vpn_mode) options.lan_vpn_mode = 'all';
        if (options.lan_vpn_macs == null) options.lan_vpn_macs = '';
        if (!options.ipv6_mode) options.ipv6_mode = 'proxy';
        if (!options.guest_vpn_mode) options.guest_vpn_mode = 'follow';
      };

      onMounted(() => {
        hydrate();
        ensureBoolDefaults();
        loadPreflight();
        loadSpeedStatus();
        loadDnsTestStatus();
        liveTimer = setInterval(() => {
          liveTick.value += 1;
        }, 2000);
      });
      onBeforeUnmount(() => {
        if (liveTimer) clearInterval(liveTimer);
        liveTimer = null;
      });
      watch(
        () => uiResponse?.value,
        () => {
          // Do not clobber in-progress edits while a save/toggle is running.
          if (busy.value) return;
          hydrate();
          ensureBoolDefaults();
        },
        { deep: true }
      );

      return {
        options,
        ipsetOptions,
        busy,
        isRunning,
        xrayuiConflict,
        conflictMessage,
        uptimeLabel,
        profileLabel,
        canCheckConnection,
        catalogSyncEnabled,
        catalogSyncSubtitle,
        catalogInterval,
        setCatalogSync,
        lanModeSubtitle,
        guestModeSubtitle,
        ipv6ModeSubtitle,
        preflightSubtitle,
        runPreflight,
        speedSubtitle,
        runSpeedTest,
        dnsTestSubtitle,
        runDnsTest,
        onStartupToggle,
        handleStatus,
        save,
        connect: SubmitActions.serverStart,
        reconnect: SubmitActions.serverRestart,
        stop: SubmitActions.serverStop
      };
    }
  });
</script>
