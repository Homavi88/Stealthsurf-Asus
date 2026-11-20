<template>
  <div class="ss-conn">
    <div v-if="xrayuiConflict" class="ss-alert" role="alert">
      <strong>{{ conflictTitle }}</strong>
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
              <option value="all">Все устройства через VPN</option>
              <option value="selected">VPN только для отмеченных</option>
              <option value="exclude">VPN для всех, кроме отмеченных (они — direct)</option>
            </select>
          </label>
          <div v-if="options.lan_vpn_mode !== 'all'" class="ss-lan-devices">
            <div class="ss-lan-devices__hint">
              {{
                options.lan_vpn_mode === 'exclude'
                  ? 'Отметьте устройства, которые идут в интернет напрямую (мимо VPN).'
                  : 'Отметьте устройства, которые должны идти через VPN; остальные — direct.'
              }}
            </div>
            <ol v-if="options.lan_vpn_mode === 'exclude'" class="ss-lan-devices__steps">
              <li>Режим: «VPN для всех, кроме отмеченных».</li>
              <li>Галочка только на устройстве, которое должно быть direct (NAS, ТВ, принтер…).</li>
              <li>Save — если VPN уже online, firewall обновится сам; иначе Start / Restart VPN.</li>
              <li>
                С телефона в том же Wi‑Fi (не guest) открывайте устройство по IP из списка
                (например <span class="ss-mono">192.168.50.112</span>) — не DDNS и не облачное имя.
              </li>
              <li>На телефоне отключите «случайный MAC» или отметьте актуальный MAC в списке.</li>
            </ol>
            <div v-else class="ss-lan-devices__hint">
              После Save при работающем VPN firewall обновится сам. Доступ в LAN — по локальному IP, не по DDNS.
            </div>
            <label v-for="d in lanDevices" :key="d.mac" class="ss-lan-devices__row">
              <input type="checkbox" :checked="isLanMacSelected(d.mac)" @change="onLanMacChange(d.mac, $event)" />
              <span class="ss-lan-devices__name">{{ d.name || d.mac }}</span>
              <span class="ss-mono ss-lan-devices__meta">{{ d.ip || '—' }} · {{ d.mac }}</span>
            </label>
            <p v-if="!lanDevices.length" class="ss-lan-devices__empty">Список LAN пуст — подождите пару секунд или введите MAC вручную ниже.</p>
            <label class="ss-field">
              <span>MAC вручную (через запятую)</span>
              <input type="text" v-model="options.lan_vpn_macs" placeholder="aa:bb:cc:dd:ee:ff, …" autocomplete="off" />
            </label>
          </div>
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

      <div class="ss-set-row has-divider">
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

      <ss-settings-row
        title="Исключить российские сайты"
        subtitle="Сайты в зонах .ru, .su и .рф будут загружаться напрямую"
        :toggle="!!options.split_bypass_ru_tlds"
        @update:toggle="(v) => (options.split_bypass_ru_tlds = v)"
      />

      <ss-settings-row
        title="Сервисы из белого списка напрямую"
        subtitle="Точечный список: госуслуги, банки, операторы связи, VK/OK/Yandex, маркетплейсы, СМИ — пойдут напрямую. Остальные сайты идут через VPN"
        :toggle="!!options.split_bypass_ru_services"
        @update:toggle="(v) => (options.split_bypass_ru_services = v)"
      />

      <div class="ss-set-row has-divider">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">Split bypass (домены)</div>
            <div class="ss-set-row-sub">Дополнительный список доменов в direct, минуя VPN</div>
          </div>
        </div>
        <div class="ss-set-row-detail">
          <label class="ss-field">
            <span>Список</span>
            <input
              type="text"
              v-model="options.split_bypass_domains"
              placeholder="example.com, geosite:category-games"
              autocomplete="off"
            />
          </label>
        </div>
      </div>

      <div class="ss-set-row">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">VPN-only (fail-closed)</div>
            <div class="ss-set-row-sub">
              Эти сервисы только через VPN; если аддон/VPN падает — соединение режется, clearnet блокируется
            </div>
          </div>
        </div>
        <div class="ss-set-row-detail">
          <label class="ss-field">
            <span>Список</span>
            <input
              type="text"
              v-model="options.split_lock_domains"
              placeholder="netflix.com, geosite:netflix"
              autocomplete="off"
            />
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
        <div class="ss-set-row-detail">
          <label class="ss-field">
            <span>Авто по cron</span>
            <select v-model="options.speedtest_interval">
              <option value="disabled">Выкл</option>
              <option value="6h">каждые 6 ч</option>
              <option value="12h">каждые 12 ч</option>
              <option value="24h">раз в сутки</option>
            </select>
          </label>
        </div>
      </div>
      <div class="ss-set-row">
        <div class="ss-set-row-main">
          <div class="ss-set-row-text">
            <div class="ss-set-row-title">DNS / IPv6 leak</div>
            <div class="ss-set-row-sub">{{ dnsTestSubtitle }}</div>
          </div>
          <div class="ss-set-row-control">
            <button type="button" class="ss-chip-btn" :disabled="busy" @click="runDnsTest">Проверить</button>
          </div>
        </div>
        <div class="ss-set-row-detail">
          <p class="ss-set-row-sub">
            WebRTC с роутера не проверить — откройте с LAN-устройства:
            <a :href="webrtcHint" target="_blank" rel="noopener">browserleaks.com/webrtc</a>
          </p>
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
          uiResponse?.value?.conflict === 'official' ||
          uiResponse?.value?.xrayui?.running === true ||
          uiResponse?.value?.xray?.xrayui?.running === true ||
          uiResponse?.value?.official?.running === true ||
          uiResponse?.value?.xray?.official?.running === true
      );
      const conflictMessage = computed(() => {
        if (uiResponse?.value?.conflict === 'official') {
          return (
            uiResponse?.value?.conflict_message ||
            uiResponse?.value?.official?.message ||
            uiResponse?.value?.xray?.official?.message ||
            t('com.ClientStatus.official_conflict_message')
          );
        }
        return (
          uiResponse?.value?.conflict_message ||
          uiResponse?.value?.xrayui?.message ||
          uiResponse?.value?.xray?.xrayui?.message ||
          t('com.ClientStatus.xrayui_conflict_message')
        );
      });
      const conflictTitle = computed(() =>
        uiResponse?.value?.conflict === 'official'
          ? t('com.ClientStatus.official_conflict_title')
          : t('com.ClientStatus.xrayui_conflict_title')
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

      type LanDevice = { ip?: string; mac: string; name?: string };
      const lanDevices = ref<LanDevice[]>([]);
      const normalizeMac = (m: string) => String(m || '').trim().toLowerCase();
      const selectedLanMacs = computed(() =>
        String(options.lan_vpn_macs || '')
          .split(/[,;\s]+/)
          .map(normalizeMac)
          .filter((m) => /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(m))
      );
      const isLanMacSelected = (mac: string) => selectedLanMacs.value.includes(normalizeMac(mac));
      const toggleLanMac = (mac: string, on: boolean) => {
        const m = normalizeMac(mac);
        if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(m)) return;
        const set = new Set(selectedLanMacs.value);
        if (on) set.add(m);
        else set.delete(m);
        options.lan_vpn_macs = Array.from(set).join(', ');
      };
      const onLanMacChange = (mac: string, ev: Event) => {
        const t = ev.target as HTMLInputElement | null;
        toggleLanMac(mac, !!t?.checked);
      };
      const loadLanDevices = async () => {
        try {
          const res = await engine.getWebData<LanDevice[]>('lan-devices');
          const list = Array.isArray(res.data) ? res.data : [];
          lanDevices.value = list
            .map((d) => ({
              ip: d.ip || '',
              mac: normalizeMac(d.mac),
              name: d.name || ''
            }))
            .filter((d) => /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(d.mac));
        } catch {
          lanDevices.value = [];
        }
      };

      const lanModeSubtitle = computed(() => {
        switch (options.lan_vpn_mode) {
          case 'selected':
            return 'VPN только для отмеченных устройств; остальные идут напрямую';
          case 'exclude':
            return 'VPN для всех, кроме отмеченных — они идут напрямую в интернет';
          default:
            return 'Весь LAN через transparent proxy (VPN)';
        }
      });
      const guestModeSubtitle = computed(() => {
        switch (options.guest_vpn_mode) {
          case 'direct':
            return 'Гостевые мосты br1/br2… без VPN';
          case 'vpn':
            return 'Гостевые br* всегда TPROXY, даже если LAN = selected/exclude';
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
        ipv6_leaked?: boolean;
        exit_ip?: string | null;
        exit_ip6?: string | null;
        webrtc_hint?: string | null;
      };
      const dnsTestStatus = ref<DnsTestStatus | null>(null);
      const webrtcHint = computed(
        () => dnsTestStatus.value?.webrtc_hint || 'https://browserleaks.com/webrtc'
      );
      const dnsTestSubtitle = computed(() => {
        if (!dnsTestStatus.value) return 'Wiring + resolvers · IPv6 · сверка с WAN DNS';
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
          }, false);
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
          'dns_only',
          'split_bypass_ru_tlds',
          'split_bypass_ru_services'
        ]) {
          if (typeof o[key] !== 'boolean') o[key] = false;
        }
        // Autostart: missing NVRAM key defaults to on (same as install).
        if (typeof o.startup !== 'boolean') {
          o.startup = window.xray?.custom_settings?.stealthsurf_startup !== 'n';
        }
        if (!options.ipsec) options.ipsec = 'off';
        if (!options.probe_url) options.probe_url = 'https://www.google.com/generate_204';
        if (!options.probe_interval) options.probe_interval = 60;
        if (!options.watchdog_interval) options.watchdog_interval = 2;
        if (options.watchdog_max_attempts == null) options.watchdog_max_attempts = 5;
        if (!options.ss_catalog_auto_sync) options.ss_catalog_auto_sync = 'disabled';
        if (options.ss_catalog_auto_sync !== 'disabled') catalogInterval.value = String(options.ss_catalog_auto_sync);
        if (!options.lan_vpn_mode) options.lan_vpn_mode = 'all';
        if (options.lan_vpn_macs == null) options.lan_vpn_macs = '';
        if (!options.ipv6_mode) options.ipv6_mode = 'proxy';
        if (!options.guest_vpn_mode) options.guest_vpn_mode = 'follow';
        if (options.split_bypass_domains == null) options.split_bypass_domains = '';
        if (options.split_lock_domains == null) options.split_lock_domains = '';
        if (!options.speedtest_interval) options.speedtest_interval = 'disabled';
      };

      onMounted(() => {
        hydrate();
        ensureBoolDefaults();
        loadPreflight();
        loadSpeedStatus();
        loadDnsTestStatus();
        loadLanDevices();
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
        conflictTitle,
        uptimeLabel,
        profileLabel,
        canCheckConnection,
        catalogSyncEnabled,
        catalogSyncSubtitle,
        catalogInterval,
        setCatalogSync,
        lanModeSubtitle,
        lanDevices,
        isLanMacSelected,
        onLanMacChange,
        guestModeSubtitle,
        ipv6ModeSubtitle,
        preflightSubtitle,
        runPreflight,
        speedSubtitle,
        runSpeedTest,
        dnsTestSubtitle,
        webrtcHint,
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
