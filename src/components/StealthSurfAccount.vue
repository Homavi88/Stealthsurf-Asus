<template>
  <div class="formfontdesc ss-account">
    <table class="FormTable SettingsTable tableApi_table">
      <thead>
        <tr>
          <td colspan="2">StealthSurf Account · {{ channelLabel }}</td>
        </tr>
      </thead>
      <tbody>
        <tr>
          <th>API key</th>
          <td>
            <input type="password" class="input_32_table" v-model="apiKey" placeholder="stlth_........_........................" autocomplete="off" />
            <input type="text" class="input_15_table" v-model="apiLabel" placeholder="label" style="margin-left: 6px; width: 100px" />
            <br />
            <input class="button_gen button_gen_small" type="button" value="Save key" @click.prevent="saveKey" />
            <input class="button_gen button_gen_small" type="button" value="Add key" @click.prevent="addKey" />
            <input class="button_gen button_gen_small" type="button" value="Sync catalog" @click.prevent="syncCatalog" />
            <input class="button_gen button_gen_small" type="button" value="Refresh balance" @click.prevent="refreshBalances(true)" />
          </td>
        </tr>
        <tr>
          <th>Balance</th>
          <td>
            <div class="ss-balance-summary">{{ balanceSummary }}</div>
            <div class="ss-hint">{{ balanceStatus }}</div>
            <table class="FormTable" style="margin-top: 8px" v-if="balanceRows.length">
              <thead>
                <tr>
                  <th>Key</th>
                  <th>Balance</th>
                  <th>Referral</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="row in balanceRows" :key="row.key_fp + row.key_tail">
                  <td>
                    <span v-if="row.label">{{ row.label }} · </span>…{{ row.key_tail }}
                    <div class="ss-hint" v-if="row.email">{{ row.email }}</div>
                    <div class="ss-hint" v-if="row.error" style="color: #ffcc00">{{ row.error }}</div>
                  </td>
                  <td>{{ row.ok ? formatRub(row.balance) : '—' }}</td>
                  <td>{{ row.ok ? formatRub(row.referral_balance) : '—' }}</td>
                  <td>
                    <input class="button_gen button_gen_small" type="button" value="Remove" @click.prevent="removeKey(row)" />
                  </td>
                </tr>
              </tbody>
            </table>
          </td>
        </tr>
        <tr>
          <th>Configs</th>
          <td>
            <div class="ss-hint">{{ configsStatus }}</div>
            <div style="max-height: 280px; overflow: auto; margin-top: 8px">
              <table class="FormTable" v-if="configs.length">
                <thead>
                  <tr>
                    <th></th>
                    <th>Title</th>
                    <th>Protocol</th>
                    <th>Online</th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-for="c in configs" :key="c.id">
                    <td><input type="checkbox" v-model="selectedIds" :value="c.id" /></td>
                    <td>
                      {{ c.title || c.name || 'ss-' + c.id }}
                      <span v-if="isImported(c.id)" class="label label-success" style="margin-left: 6px">imported</span>
                    </td>
                    <td>{{ c.protocol || '—' }}</td>
                    <td>
                      <span :class="c.is_online ? 'label label-success' : 'label label-error'">{{ c.is_online ? 'online' : 'offline' }}</span>
                    </td>
                  </tr>
                </tbody>
              </table>
              <div v-else class="ss-hint">No catalog yet — add an API key and Sync.</div>
            </div>
            <input
              class="button_gen button_gen_small"
              type="button"
              value="Import selected → Outbounds"
              :disabled="!selectedIds.length"
              @click.prevent="importSelected"
              style="margin-top: 8px"
            />
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, inject, onMounted, ref, Ref } from 'vue';
  import axios from 'axios';
  import engine, { EngineResponseConfig, SubmitActions } from '@/modules/Engine';
  import { outboundSsId, parseCatalogPayload } from '@/modules/StealthSurfCatalog';

  const SS_API_BASE = 'https://api.stealthsurf.net';

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

  interface SsConfig {
    id: number | string;
    title?: string;
    name?: string;
    protocol?: string;
    is_online?: boolean;
    connection_url?: string;
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
    name: 'StealthSurfAccount',
    setup() {
      const apiKey = ref('');
      const apiLabel = ref('');
      const balances = ref<BalancesPayload | null>(null);
      const balanceStatus = ref('Not fetched yet');
      const configs = ref<SsConfig[]>([]);
      const selectedIds = ref<(number | string)[]>([]);
      const configsStatus = ref('');
      const uiResponse = inject<Ref<EngineResponseConfig>>('uiResponse', ref({} as EngineResponseConfig));
      const channelLabel = computed(() => {
        const v = uiResponse.value?.xray?.ui_version;
        return v ? `${v} beta` : '1.1.x beta';
      });
      const importedIds = computed(() => {
        const ids = new Set<string>();
        (engine.xrayConfig.outbounds || []).forEach((o) => {
          const id = outboundSsId(o);
          if (id) ids.add(id);
        });
        return ids;
      });
      const isImported = (id: number | string) => importedIds.value.has(String(id));

      const formatRub = (n: number | null | undefined) => {
        if (n == null || Number.isNaN(Number(n))) return '—';
        return `${Number(n).toLocaleString('ru-RU', { maximumFractionDigits: 2 })} ₽`;
      };

      const balanceRows = computed(() => balances.value?.keys || []);
      const balanceSummary = computed(() => {
        const data = balances.value;
        if (!data || !data.keys?.length) return 'balance: —';
        const ok = data.keys.filter((k) => k.ok);
        if (!ok.length) return data.message || 'balance unavailable';
        if (ok.length === 1) return `balance: ${formatRub(ok[0].balance)}`;
        return `balance: ${formatRub(data.total_balance)} (${ok.length} keys)`;
      });

      const loadCaches = async () => {
        try {
          const bal = await engine.getWebData<BalancesPayload>('balances');
          if (bal?.data) {
            balances.value = bal.data;
            balanceStatus.value = bal.data.message || 'Cached';
          }
        } catch {
          /* empty */
        }
        try {
          const cfg = await engine.getWebData<SsConfig[] | { data?: SsConfig[] }>('ss_configs');
          const next = parseCatalogPayload(cfg?.data);
          if (next.length) {
            configs.value = next;
            configsStatus.value = `${next.length} configs in catalog`;
          }
        } catch {
          configsStatus.value = 'Catalog not loaded';
        }
      };

      const refreshBalancesBrowser = async () => {
        try {
          const keysResp = await engine.getWebData<{ key: string; label?: string }[]>('api_keys');
          const keys = Array.isArray(keysResp?.data) ? keysResp.data : [];
          if (!keys.length) {
            balanceStatus.value = 'No API keys saved';
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
                error: e?.response?.data?.message || 'request failed'
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
            message: okRows.length ? 'Balances updated' : 'Failed to fetch balances'
          };
          balances.value = payload;
          balanceStatus.value = payload.message || '';
          return payload;
        } catch {
          return null;
        }
      };

      const refreshBalances = async (forceRouter = false) => {
        balanceStatus.value = 'Refreshing…';
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
          alert('Enter API key');
          return;
        }
        await engine.submit(SubmitActions.ssSetKey, { api_key: key, label: apiLabel.value.trim() || 'primary' }, 3);
        apiKey.value = '';
        await refreshBalances(true);
        await loadCaches();
      };

      const addKey = async () => {
        const key = apiKey.value.trim();
        if (!key) {
          alert('Enter API key');
          return;
        }
        await engine.submit(SubmitActions.ssAddKey, { api_key: key, label: apiLabel.value.trim() }, 3);
        apiKey.value = '';
        await refreshBalances(true);
        await loadCaches();
      };

      const removeKey = async (row: BalanceRow) => {
        // Prefer exact key from browser cache; else ask backend via tail+fp is not enough — use stored list
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
          alert('Could not resolve full key to remove');
          return;
        }
        if (!confirm(`Remove key …${row.key_tail}?`)) return;
        await engine.submit(SubmitActions.ssRemoveKey, { api_key: key }, 2);
        await refreshBalances(true);
        await loadCaches();
      };

      const syncCatalog = async () => {
        configsStatus.value = 'Syncing…';
        await engine.submit(SubmitActions.ssSync, null, 8);
        await loadCaches();
        await refreshBalances(false);
      };

      const importSelected = async () => {
        if (!selectedIds.value.length) return;
        await engine.executeWithLoadingProgress(async () => {
          await engine.submit(SubmitActions.ssImportConfigs, { ids: selectedIds.value }, 10);
          await engine.loadXrayConfig();
        });
        await loadCaches();
        alert('Imported with API titles. DNS leak protection is on. After Start/Restart Outbounds show 🟢/🔴 and catalog online dots.');
      };

      onMounted(async () => {
        await loadCaches();
        await refreshBalances(false);
      });

      return {
        apiKey,
        apiLabel,
        balanceRows,
        balanceSummary,
        balanceStatus,
        configs,
        configsStatus,
        selectedIds,
        channelLabel,
        isImported,
        formatRub,
        saveKey,
        addKey,
        removeKey,
        syncCatalog,
        refreshBalances,
        importSelected
      };
    }
  });
</script>

<style scoped>
  .ss-hint {
    color: #a0a7a7;
    font-size: 12px;
    margin-top: 4px;
  }
  .ss-balance-summary {
    font-weight: 600;
  }
  .ss-account .button_gen_small {
    margin: 4px 4px 0 0;
  }
</style>
