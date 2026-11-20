<template>
  <div class="ss-acct">
    <div class="ss-acct-card">
      <div class="ss-acct-label">Активная подписка</div>
      <select class="ss-acct-select" v-model="activeKeyFp" @change="onActiveKeyChange">
        <option v-for="row in balanceRows" :key="(row.key_fp || '') + (row.key_tail || '')" :value="row.key_fp || row.key_tail || ''">
          {{ keyLabel(row) }}
        </option>
        <option v-if="!balanceRows.length" value="">Нет ключей</option>
      </select>
      <p class="ss-acct-hint">
        Баланс:
        <strong>{{ activeBalanceLabel }}</strong>
        <span v-if="activeEmail"> · {{ activeEmail }}</span>
      </p>
      <p class="ss-acct-hint">
        Дополнительные ключи и пополнение — через API StealthSurf. Каталог синхронизируется с
        <a href="https://stealthsurf.ru" target="_blank" rel="noopener noreferrer">консолью</a>.
      </p>
    </div>

    <div class="ss-acct-card">
      <button type="button" class="ss-acct-row" @click="showAddKey = !showAddKey">
        <div>
          <div class="ss-acct-row__title">Добавить подписку</div>
          <div class="ss-acct-row__sub">Привяжите другой API-ключ (stlth_…)</div>
        </div>
        <span class="ss-acct-row__chev">{{ showAddKey ? '▾' : '›' }}</span>
      </button>
      <div v-if="showAddKey" style="margin-top: 12px">
        <label class="ss-field">
          API-ключ
          <input type="password" v-model="apiKey" placeholder="stlth_........_........................" autocomplete="off" />
        </label>
        <label class="ss-field">
          Метка
          <input type="text" v-model="apiLabel" placeholder="Основная подписка" />
        </label>
        <div class="ss-acct-actions">
          <button type="button" class="ss-chip-btn" @click.prevent="saveKey">Сохранить ключ</button>
          <button type="button" class="ss-chip-btn" @click.prevent="addKey">Добавить ещё</button>
        </div>
      </div>
    </div>

    <div class="ss-acct-card">
      <div class="ss-acct-label">Ключи и баланс</div>
      <div class="ss-acct-keys" v-if="balanceRows.length">
        <div class="ss-acct-key" v-for="row in balanceRows" :key="(row.key_fp || '') + (row.key_tail || '')">
          <div class="ss-acct-key__main">
            <div class="ss-acct-key__title">{{ keyLabel(row) }}</div>
            <div class="ss-acct-key__meta">
              <span v-if="row.email">{{ row.email }} · </span>…{{ row.key_tail }}
              <span v-if="row.error" style="color: var(--ss-danger)"> · {{ row.error }}</span>
            </div>
          </div>
          <div class="ss-acct-key__bal">{{ row.ok ? formatRub(row.balance) : '—' }}</div>
          <button type="button" class="ss-chip-btn danger" @click.prevent="removeKey(row)">Удалить</button>
        </div>
      </div>
      <p v-else class="ss-acct-hint">{{ balanceStatus || 'Ключи ещё не загружены' }}</p>
      <div class="ss-acct-actions">
        <button type="button" class="ss-chip-btn" @click.prevent="syncCatalog">Синхронизировать каталог</button>
        <button type="button" class="ss-chip-btn" @click.prevent="refreshBalances(true)">Обновить баланс</button>
      </div>
      <div class="ss-acct-actions">
        <label class="ss-field" style="flex: 1; margin: 0">
          Пополнение, ₽
          <input type="number" v-model.number="topupAmount" min="10" step="10" />
        </label>
        <button type="button" class="ss-chip-btn" style="align-self: end" @click.prevent="doTopup">Пополнить</button>
        <button type="button" class="ss-chip-btn" style="align-self: end" @click.prevent="doTopupCalc">Расчёт</button>
      </div>
      <p v-if="topupHint" class="ss-acct-hint">{{ topupHint }}</p>
    </div>

    <div class="ss-acct-card">
      <div class="ss-acct-label">Конфиги каталога</div>
      <p class="ss-acct-hint">{{ configsStatus }}</p>
      <div class="ss-acct-configs" v-if="configs.length">
        <div class="ss-acct-cfg" v-for="c in configs" :key="catalogTag(c)">
          <input type="checkbox" v-model="selectedIds" :value="importKey(c)" />
          <div>
            <div class="ss-acct-cfg__title">
              {{ catalogTitle(c) }}
              <span v-if="isImported(c)" class="label label-success" style="margin-left: 6px">imported</span>
            </div>
            <div class="ss-acct-cfg__meta">
              {{ catalogSourceLabel(c) }} · {{ c.protocol || '—' }} ·
              {{ catalogLocationLabel(c, locations) }} · {{ formatExpiresAt(c.expires_at) }}
            </div>
          </div>
          <div style="text-align: right">
            <div class="ss-acct-cfg__online" :class="{ 'is-off': !c.is_online }">
              {{ c.is_online ? 'онлайн' : 'офлайн' }}
            </div>
            <button type="button" class="ss-chip-btn" style="margin-top: 6px" @click.prevent="openManage(c)">Управление</button>
          </div>
        </div>
      </div>
      <p v-else class="ss-acct-hint">Каталог пуст — добавьте API-ключ и синхронизируйте.</p>
      <div class="ss-acct-actions">
        <button
          type="button"
          class="ss-primary-btn start"
          style="width: auto; padding: 10px 16px; font-size: 13px"
          :disabled="!selectedIds.length"
          @click.prevent="importSelected"
        >
          Импорт выбранных → Outbounds
        </button>
      </div>
    </div>

    <ss-api-info-modal ref="infoModal" />
    <ss-config-manage-modal ref="manageModal" :locations="locations" @stats="onStats" @traffic="onTraffic" @updated="onManagedUpdated" />
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, onMounted, ref } from 'vue';
  import axios from 'axios';
  import engine, { SubmitActions } from '@/modules/Engine';
  import SsApiInfoModal from '@modal/SsApiInfoModal.vue';
  import SsConfigManageModal from '@modal/SsConfigManageModal.vue';
  import { SS_API_BASE, ssApiGet } from '@/modules/StealthSurfApiClient';
  import {
    SsCatalogConfig,
    SsLocation,
    catalogLocationLabel,
    catalogSourceLabel,
    catalogTag,
    catalogTitle,
    enrichCatalogWithLocations,
    formatExpiresAt,
    outboundSsId,
    parseCatalogPayload
  } from '@/modules/StealthSurfCatalog';

  interface BalanceRow {
    ok?: boolean;
    label?: string;
    key_fp?: string;
    key_tail?: string;
    email?: string | null;
    balance?: number | null;
    referral_balance?: number | null;
    error?: string | null;
    key?: string;
  }

  interface BalancesPayload {
    fetched_at?: number;
    keys?: BalanceRow[];
    total_balance?: number;
    total_referral?: number;
    currency?: string;
    message?: string;
  }

  export default defineComponent({
    name: 'PanelAccount',
    components: { SsApiInfoModal, SsConfigManageModal },
    emits: ['profile'],
    setup(_, { emit }) {
      const apiKey = ref('');
      const apiLabel = ref('Основная подписка');
      const balances = ref<BalancesPayload | null>(null);
      const balanceStatus = ref('Ещё не загружено');
      const configs = ref<SsCatalogConfig[]>([]);
      const locations = ref<SsLocation[]>([]);
      const selectedIds = ref<(number | string)[]>([]);
      const configsStatus = ref('');
      const topupAmount = ref(100);
      const topupHint = ref('');
      const showAddKey = ref(false);
      const activeKeyFp = ref('');
      const infoModal = ref<{ showStats: (c: SsCatalogConfig) => Promise<void>; showTraffic: (c: SsCatalogConfig) => Promise<void> } | null>(null);
      const manageModal = ref<{ show: (c: SsCatalogConfig) => void } | null>(null);

      const importedTags = computed(() => {
        const tags = new Set<string>();
        (engine.xrayConfig.outbounds || []).forEach((o) => {
          if (o.tag?.startsWith('ss-')) tags.add(o.tag);
          const id = outboundSsId(o);
          if (id) tags.add(`ss-${id}`);
        });
        return tags;
      });

      const isImported = (c: SsCatalogConfig) => importedTags.value.has(catalogTag(c)) || importedTags.value.has(`ss-${c.id}`);
      const importKey = (c: SsCatalogConfig) => catalogTag(c);

      const formatRub = (n: number | null | undefined) => {
        if (n == null || Number.isNaN(Number(n))) return '—';
        return `${Number(n).toLocaleString('ru-RU', { maximumFractionDigits: 2 })} ₽`;
      };

      const balanceRows = computed(() => balances.value?.keys || []);

      const activeRow = computed(() => {
        const rows = balanceRows.value;
        if (!rows.length) return null;
        return rows.find((r) => (r.key_fp || r.key_tail) === activeKeyFp.value) || rows.find((r) => r.ok) || rows[0];
      });

      const activeBalanceLabel = computed(() => {
        const row = activeRow.value;
        if (row?.ok) return formatRub(row.balance);
        if (balances.value?.total_balance != null) return formatRub(balances.value.total_balance);
        return '—';
      });

      const activeEmail = computed(() => activeRow.value?.email || '');

      const emitProfile = () => {
        const row = activeRow.value;
        emit('profile', {
          email: row?.email || '',
          balance: activeBalanceLabel.value,
          label: row ? keyLabel(row) : 'Основная подписка'
        });
      };

      const keyLabel = (row: BalanceRow) => row.label?.trim() || (row.ok ? 'Основная подписка' : `…${row.key_tail || 'key'}`);

      const onActiveKeyChange = () => emitProfile();

      const loadLocationsBrowser = async (): Promise<SsLocation[] | null> => {
        try {
          const data = await ssApiGet<SsLocation[]>('/locations');
          return Array.isArray(data) ? data : null;
        } catch {
          return null;
        }
      };

      const loadCaches = async () => {
        try {
          const bal = await engine.getWebData<BalancesPayload>('balances');
          if (bal?.data) {
            balances.value = bal.data;
            balanceStatus.value = bal.data.message || 'Кэш';
            if (!activeKeyFp.value && bal.data.keys?.length) {
              const first = bal.data.keys.find((k) => k.ok) || bal.data.keys[0];
              activeKeyFp.value = first.key_fp || first.key_tail || '';
            }
            emitProfile();
          }
        } catch {
          /* empty */
        }

        let nextConfigs: SsCatalogConfig[] = [];
        try {
          const cfg = await engine.getWebData<SsCatalogConfig[] | { data?: SsCatalogConfig[] }>('ss_configs');
          nextConfigs = parseCatalogPayload(cfg?.data);
        } catch {
          configsStatus.value = 'Каталог не загружен';
        }

        let nextLocs: SsLocation[] = [];
        try {
          const loc = await engine.getWebData<SsLocation[] | { data?: SsLocation[] }>('ss_locations');
          const raw = loc?.data;
          nextLocs = Array.isArray(raw) ? raw : Array.isArray((raw as { data?: SsLocation[] })?.data) ? (raw as { data: SsLocation[] }).data : [];
        } catch {
          nextLocs = [];
        }

        if (!nextLocs.length) {
          const browserLocs = await loadLocationsBrowser();
          if (browserLocs?.length) nextLocs = browserLocs;
        }

        locations.value = nextLocs;
        if (nextConfigs.length) {
          configs.value = enrichCatalogWithLocations(nextConfigs, nextLocs);
          configsStatus.value = `${configs.value.length} конфиг.` + (nextLocs.length ? ` · ${nextLocs.length} локаций` : '');
        } else if (!configsStatus.value) {
          configsStatus.value = 'Каталог пуст — добавьте API-ключ и синхронизируйте.';
        }
      };

      const refreshBalancesBrowser = async () => {
        try {
          const keysResp = await engine.getWebData<{ key: string; label?: string }[]>('api_keys');
          const keys = Array.isArray(keysResp?.data) ? keysResp.data : [];
          if (!keys.length) {
            balanceStatus.value = 'Нет сохранённых API-ключей';
            return null;
          }
          const rows: BalanceRow[] = [];
          for (const stored of keys) {
            if (!stored?.key) continue;
            try {
              const { data } = await axios.get(`${SS_API_BASE}/profile`, {
                headers: { Authorization: `Bearer ${stored.key}`, Accept: 'application/json' },
                timeout: 12000
              });
              const profile = data?.data || {};
              rows.push({
                ok: true,
                label: stored.label || '',
                key_fp: stored.key.split('_')[1] || '',
                key_tail: stored.key.slice(-8),
                key: stored.key,
                email: profile.email ? String(profile.email).replace(/^(.{2}).+(@.+)$/, '$1***$2') : null,
                balance: Number(profile.balance ?? 0),
                referral_balance: Number(profile.referral_balance ?? 0),
                error: null
              });
            } catch (e: any) {
              rows.push({
                ok: false,
                label: stored.label || '',
                key_fp: stored.key.split('_')[1] || '',
                key_tail: stored.key.slice(-8),
                key: stored.key,
                balance: null,
                referral_balance: null,
                error: e?.response?.data?.message || 'ошибка запроса'
              });
            }
          }
          const okRows = rows.filter((r) => r.ok);
          const payload: BalancesPayload = {
            fetched_at: Math.floor(Date.now() / 1000),
            keys: rows,
            total_balance: okRows.reduce((s, r) => s + Number(r.balance || 0), 0),
            total_referral: okRows.reduce((s, r) => s + Number(r.referral_balance || 0), 0),
            currency: 'RUB',
            message: okRows.length ? 'Баланс обновлён' : 'Не удалось получить баланс'
          };
          balances.value = payload;
          balanceStatus.value = payload.message || '';
          if (!activeKeyFp.value && rows.length) {
            activeKeyFp.value = (okRows[0] || rows[0]).key_fp || (okRows[0] || rows[0]).key_tail || '';
          }
          emitProfile();
          return payload;
        } catch {
          return null;
        }
      };

      const refreshBalances = async (forceRouter = false) => {
        balanceStatus.value = 'Обновление…';
        const browser = await refreshBalancesBrowser();
        if (browser) return;
        if (forceRouter) {
          await engine.submit(SubmitActions.ssBalances, null, 2);
        }
        await loadCaches();
      };

      const saveKey = async () => {
        const key = apiKey.value.trim();
        if (!key) {
          alert('Введите API-ключ');
          return;
        }
        await engine.submit(SubmitActions.ssSetKey, { api_key: key, label: apiLabel.value.trim() || 'Основная подписка' }, 3);
        apiKey.value = '';
        showAddKey.value = false;
        await refreshBalances(true);
        await loadCaches();
      };

      const addKey = async () => {
        const key = apiKey.value.trim();
        if (!key) {
          alert('Введите API-ключ');
          return;
        }
        await engine.submit(SubmitActions.ssAddKey, { api_key: key, label: apiLabel.value.trim() }, 3);
        apiKey.value = '';
        showAddKey.value = false;
        await refreshBalances(true);
        await loadCaches();
      };

      const removeKey = async (row: BalanceRow) => {
        let key = row.key;
        if (!key) {
          try {
            const keysResp = await engine.getWebData<{ key: string; label?: string }[]>('api_keys');
            const keys = Array.isArray(keysResp?.data) ? keysResp.data : [];
            key = keys.find((k) => k.key?.endsWith(row.key_tail || '') && k.key?.includes(row.key_fp || ''))?.key;
          } catch {
            /* empty */
          }
        }
        if (!key) {
          alert('Не удалось определить полный ключ для удаления');
          return;
        }
        if (!confirm(`Удалить ключ …${row.key_tail}?`)) return;
        await engine.submit(SubmitActions.ssRemoveKey, { api_key: key }, 2);
        await refreshBalances(true);
        await loadCaches();
      };

      const syncCatalog = async () => {
        configsStatus.value = 'Синхронизация…';
        await engine.submit(SubmitActions.ssSync, null, 12);
        await loadCaches();
        await refreshBalances(false);
      };

      const importSelected = async () => {
        if (!selectedIds.value.length) return;
        const ids = selectedIds.value.map((v) => {
          const c = configs.value.find((x) => importKey(x) === v || String(x.id) === String(v));
          return c ? c.id : v;
        });
        await engine.executeWithLoadingProgress(async () => {
          await engine.submit(SubmitActions.ssImportConfigs, { ids }, 12);
          await engine.loadXrayConfig();
        });
        await loadCaches();
        alert('Импортировано. После Start/Restart Outbounds покажут 🟢/🔴.');
      };

      const openManage = (c: SsCatalogConfig) => manageModal.value?.show(c);
      const onStats = async (c: SsCatalogConfig) => infoModal.value?.showStats(c);
      const onTraffic = async (c: SsCatalogConfig) => infoModal.value?.showTraffic(c);
      const onManagedUpdated = async () => {
        await loadCaches();
      };

      const doTopup = async () => {
        if (!topupAmount.value || topupAmount.value < 10) {
          alert('Сумма должна быть ≥ 10');
          return;
        }
        await engine.submit(SubmitActions.ssTopup, { amount: topupAmount.value }, 6);
        topupHint.value = 'Запрос на пополнение отправлен — проверьте ссылку оплаты / аккаунт';
        await refreshBalances(true);
      };

      const doTopupCalc = async () => {
        try {
          const data = await ssApiGet<unknown>(`/profile/balance/calculate?amount=${topupAmount.value || 100}`);
          topupHint.value = `Расчёт: ${JSON.stringify(data || {}).slice(0, 220)}`;
        } catch (e: any) {
          topupHint.value = e?.response?.data?.message || e?.message || 'Расчёт не удался';
        }
      };

      onMounted(async () => {
        await loadCaches();
        await refreshBalances(false);
      });

      return {
        apiKey,
        apiLabel,
        balanceRows,
        balanceStatus,
        configs,
        configsStatus,
        selectedIds,
        locations,
        topupAmount,
        topupHint,
        showAddKey,
        activeKeyFp,
        activeBalanceLabel,
        activeEmail,
        infoModal,
        manageModal,
        catalogTitle,
        catalogTag,
        catalogSourceLabel,
        catalogLocationLabel,
        formatExpiresAt,
        formatRub,
        keyLabel,
        isImported,
        importKey,
        onActiveKeyChange,
        saveKey,
        addKey,
        removeKey,
        syncCatalog,
        refreshBalances,
        importSelected,
        openManage,
        onStats,
        onTraffic,
        onManagedUpdated,
        doTopup,
        doTopupCalc
      };
    }
  });
</script>
