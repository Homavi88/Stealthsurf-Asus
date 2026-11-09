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
            <div style="margin-top: 10px">
              <input type="number" class="input_15_table" v-model.number="topupAmount" min="10" step="10" style="width: 90px" />
              <input class="button_gen button_gen_small" type="button" value="Top-up" @click.prevent="doTopup" />
              <input class="button_gen button_gen_small" type="button" value="Calc" @click.prevent="doTopupCalc" />
              <div class="ss-hint" v-if="topupHint">{{ topupHint }}</div>
            </div>
          </td>
        </tr>
        <tr>
          <th>Configs</th>
          <td>
            <div class="ss-hint">{{ configsStatus }}</div>
            <div style="max-height: 320px; overflow: auto; margin-top: 8px">
              <table class="FormTable" v-if="configs.length">
                <thead>
                  <tr>
                    <th></th>
                    <th>Title</th>
                    <th>Src</th>
                    <th>Proto</th>
                    <th>Location</th>
                    <th>Expires</th>
                    <th>Renew</th>
                    <th>Online</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="c in configs"
                    :key="catalogTag(c)"
                    :class="{ 'ss-row-active': selectedDetailTag === catalogTag(c) }"
                    @click="selectConfig(c)"
                  >
                    <td @click.stop>
                      <input type="checkbox" v-model="selectedIds" :value="importKey(c)" />
                    </td>
                    <td>
                      {{ catalogTitle(c) }}
                      <span v-if="isImported(c)" class="label label-success" style="margin-left: 6px">imported</span>
                    </td>
                    <td>{{ catalogSourceLabel(c) }}</td>
                    <td>{{ c.protocol || '—' }}</td>
                    <td>{{ c._ss_location_title || c.location_id || '—' }}</td>
                    <td>{{ formatExpiresAt(c.expires_at) }}</td>
                    <td>{{ c.auto_renewal ? (c.auto_renewal_days ? c.auto_renewal_days + 'd' : 'on') : '—' }}</td>
                    <td>
                      <span :class="c.is_online ? 'label label-success' : 'label label-error'">{{
                        c.is_online ? 'online' : 'offline'
                      }}</span>
                    </td>
                  </tr>
                </tbody>
              </table>
              <div v-else class="ss-hint">No catalog yet — add an API key and Sync.</div>
            </div>
            <div class="ss-hint" style="margin-top: 6px">
              Auto-poll + rebuild on provider changes: General Options → StealthSurf → Auto-sync catalog. Paid/cloud rows appear after Sync.
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
        <tr v-if="activeConfig">
          <th>Selected</th>
          <td>
            <div class="ss-selected-title">{{ catalogTitle(activeConfig) }} · {{ catalogTag(activeConfig) }}</div>
            <div class="ss-hint">
              id={{ activeConfig.id }} · location={{ activeConfig.location_id || '—' }} · server={{ activeConfig.server_id || '—' }}
            </div>

            <div class="ss-panel" v-if="(activeConfig._ss_source || 'config') === 'config'">
              <div class="ss-panel-title">Change settings (PATCH)</div>
              <label class="ss-field">
                Protocol
                <select v-model="editProtocol" class="input_option">
                  <option v-for="p in protocols" :key="p" :value="p">{{ p }}</option>
                </select>
              </label>
              <label class="ss-field">
                Location id
                <select v-model.number="editLocationId" class="input_option">
                  <option v-for="loc in locations" :key="loc.id" :value="loc.id">
                    {{ loc.title || loc.code || loc.id }}
                  </option>
                </select>
              </label>
              <label class="ss-field">
                Server id
                <select v-model="editServerId" class="input_option">
                  <option value="">auto</option>
                  <option v-for="s in availableServers" :key="s.id" :value="String(s.id)">
                    {{ s.id }} · {{ s.ip || '?' }} (slots {{ s.available_slots ?? '—' }})
                  </option>
                </select>
              </label>
              <label class="ss-check"><input type="checkbox" v-model="editDisableReality" /> disable REALITY</label>
              <label class="ss-check"><input type="checkbox" v-model="editChangeSni" /> change SNI</label>
              <label class="ss-check"><input type="checkbox" v-model="editUseXhttp" /> XHTTP</label>
              <label class="ss-check"><input type="checkbox" v-model="editUseGrpc" /> gRPC</label>
              <div>
                <input class="button_gen button_gen_small" type="button" value="Load servers" @click.prevent="loadServers" />
                <input class="button_gen button_gen_small" type="button" value="Apply settings" @click.prevent="applySettings" />
                <input class="button_gen button_gen_small" type="button" value="Autofit (ISP)" @click.prevent="runAutofit" />
              </div>
              <div class="ss-hint" v-if="autofitStatus">{{ autofitStatus }}</div>
            </div>

            <div class="ss-panel">
              <div class="ss-panel-title">Stats & traffic</div>
              <input class="button_gen button_gen_small" type="button" value="Server stats" @click.prevent="loadServerStats" />
              <input class="button_gen button_gen_small" type="button" value="Traffic" @click.prevent="loadTraffic" />
              <div class="ss-hint">Opens StealthSurf modal (no router Please wait).</div>
            </div>

            <div class="ss-panel" v-if="(activeConfig._ss_source || 'config') === 'config'">
              <div class="ss-panel-title">Billing</div>
              <label class="ss-check">
                <input type="checkbox" v-model="editAutoRenewal" /> auto-renewal
              </label>
              <input type="number" class="input_6_table" v-model.number="editAutoRenewDays" min="1" style="width: 60px" />
              days
              <input class="button_gen button_gen_small" type="button" value="Save renewal" @click.prevent="saveAutoRenewal" />
              <input class="button_gen button_gen_small" type="button" value="Renew now" @click.prevent="renewNow" />
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    <ss-api-info-modal ref="infoModal" />
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, inject, onMounted, ref, Ref, watch } from 'vue';
  import axios from 'axios';
  import engine, { EngineResponseConfig, SubmitActions } from '@/modules/Engine';
  import SsApiInfoModal from '@modal/SsApiInfoModal.vue';
  import { SS_API_BASE, ssApiGet } from '@/modules/StealthSurfApiClient';
  import {
    SS_PROTOCOLS,
    SsCatalogConfig,
    catalogSourceLabel,
    catalogTag,
    catalogTitle,
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

  interface SsLocation {
    id: number;
    title?: string;
    code?: string;
  }

  interface AvailableServer {
    id: number;
    ip?: string;
    available_slots?: number;
  }

  export default defineComponent({
    name: 'StealthSurfAccount',
    components: { SsApiInfoModal },
    setup() {
      const apiKey = ref('');
      const apiLabel = ref('');
      const balances = ref<BalancesPayload | null>(null);
      const balanceStatus = ref('Not fetched yet');
      const configs = ref<SsCatalogConfig[]>([]);
      const locations = ref<SsLocation[]>([]);
      const selectedIds = ref<(number | string)[]>([]);
      const selectedDetailTag = ref('');
      const configsStatus = ref('');
      const availableServers = ref<AvailableServer[]>([]);
      const protocols = SS_PROTOCOLS;
      const editProtocol = ref('vless');
      const editLocationId = ref<number | ''>('');
      const editServerId = ref('');
      const editDisableReality = ref(false);
      const editChangeSni = ref(false);
      const editUseXhttp = ref(false);
      const editUseGrpc = ref(false);
      const editAutoRenewal = ref(false);
      const editAutoRenewDays = ref(30);
      const autofitStatus = ref('');
      const topupAmount = ref(100);
      const topupHint = ref('');
      const infoModal = ref<{ showStats: (c: SsCatalogConfig) => Promise<void>; showTraffic: (c: SsCatalogConfig) => Promise<void> } | null>(null);

      const uiResponse = inject<Ref<EngineResponseConfig>>('uiResponse', ref({} as EngineResponseConfig));
      const channelLabel = computed(() => {
        const v = uiResponse.value?.xray?.ui_version;
        return v ? `${v} beta` : '1.1.x beta';
      });

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
      const activeConfig = computed(() => configs.value.find((c) => catalogTag(c) === selectedDetailTag.value) || null);

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

      const selectConfig = (c: SsCatalogConfig) => {
        selectedDetailTag.value = catalogTag(c);
        editProtocol.value = c.protocol || 'vless';
        editLocationId.value = c.location_id != null ? Number(c.location_id) : '';
        editServerId.value = c.server_id != null ? String(c.server_id) : '';
        editAutoRenewal.value = !!c.auto_renewal;
        editAutoRenewDays.value = c.auto_renewal_days || 30;
        editDisableReality.value = false;
        editChangeSni.value = false;
        editUseXhttp.value = false;
        editUseGrpc.value = false;
        autofitStatus.value = '';
      };

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
          const cfg = await engine.getWebData<SsCatalogConfig[] | { data?: SsCatalogConfig[] }>('ss_configs');
          const next = parseCatalogPayload(cfg?.data);
          if (next.length) {
            configs.value = next;
            configsStatus.value = `${next.length} configs in catalog`;
            if (!selectedDetailTag.value && next[0]) selectConfig(next[0]);
          }
        } catch {
          configsStatus.value = 'Catalog not loaded';
        }
        try {
          const loc = await engine.getWebData<SsLocation[] | { data?: SsLocation[] }>('ss_locations');
          const raw = loc?.data;
          locations.value = Array.isArray(raw) ? raw : Array.isArray((raw as { data?: SsLocation[] })?.data) ? (raw as { data: SsLocation[] }).data : [];
        } catch {
          locations.value = [];
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
        await engine.submit(SubmitActions.ssSync, null, 12);
        await loadCaches();
        await refreshBalances(false);
      };

      const importSelected = async () => {
        if (!selectedIds.value.length) return;
        // Backend accepts ids; pass numeric ids when possible, else tags (catalog lookup supports both).
        const ids = selectedIds.value.map((v) => {
          const c = configs.value.find((x) => importKey(x) === v || String(x.id) === String(v));
          return c ? c.id : v;
        });
        await engine.executeWithLoadingProgress(async () => {
          await engine.submit(SubmitActions.ssImportConfigs, { ids }, 12);
          await engine.loadXrayConfig();
        });
        await loadCaches();
        alert('Imported. After Start/Restart Outbounds show 🟢/🔴. Paid/cloud use ss-po-* / ss-cs-* tags.');
      };

      const loadServers = async () => {
        if (!activeConfig.value || editLocationId.value === '') return;
        try {
          const data = await ssApiGet<AvailableServer[]>(
            `/configs/available-servers?location_id=${editLocationId.value}&protocol=${encodeURIComponent(editProtocol.value)}`
          );
          availableServers.value = Array.isArray(data) ? data : [];
        } catch (e: any) {
          availableServers.value = [];
          alert(e?.response?.data?.message || e?.message || 'Could not load available servers');
        }
      };

      const applySettings = async () => {
        const c = activeConfig.value;
        if (!c) return;
        if (!confirm('PATCH settings recreates the provider config. Continue?')) return;
        const body: Record<string, unknown> = {
          id: c.id,
          source: c._ss_source || 'config',
          parent_id: c._ss_parent_id || undefined,
          location_id: editLocationId.value,
          protocol: editProtocol.value
        };
        if (editServerId.value) body.server_id = Number(editServerId.value);
        if (editDisableReality.value) body.disable_reality = true;
        if (editChangeSni.value) body.change_sni = true;
        if (editUseXhttp.value) body.use_xhttp = true;
        if (editUseGrpc.value) body.use_grpc = true;
        await engine.executeWithLoadingProgress(async () => {
          await engine.submit(SubmitActions.ssUpdateSettings, body, 15);
          await engine.loadXrayConfig();
        });
        await loadCaches();
      };

      const runAutofit = async () => {
        const c = activeConfig.value;
        if (!c) return;
        if (!confirm('Autofit will try servers/protocols/flags via API until Observatory is green. Continue?')) return;
        autofitStatus.value = 'Running autofit…';
        await engine.executeWithLoadingProgress(async () => {
          await engine.submit(SubmitActions.ssAutofit, { id: c.id }, 90);
          await engine.loadXrayConfig();
        });
        try {
          const resp = await engine.getWebData<{ status?: string; winner?: unknown; attempts?: unknown[] }>('ss_autofit');
          const st = resp?.data?.status || 'unknown';
          autofitStatus.value =
            st === 'ok' ? `OK — ${JSON.stringify(resp.data?.winner || {})}` : `Finished: ${st} (${resp?.data?.attempts?.length || 0} attempts)`;
        } catch {
          autofitStatus.value = 'Autofit finished (see system log)';
        }
        await loadCaches();
      };

      const loadServerStats = async () => {
        const c = activeConfig.value;
        if (!c || !infoModal.value) return;
        await infoModal.value.showStats(c);
      };

      const loadTraffic = async () => {
        const c = activeConfig.value;
        if (!c || !infoModal.value) return;
        await infoModal.value.showTraffic(c);
      };

      const saveAutoRenewal = async () => {
        const c = activeConfig.value;
        if (!c) return;
        await engine.submit(
          SubmitActions.ssAutoRenewal,
          { id: c.id, enabled: editAutoRenewal.value, days: editAutoRenewDays.value },
          4
        );
        await loadCaches();
      };

      const renewNow = async () => {
        const c = activeConfig.value;
        if (!c) return;
        if (!confirm(`Request renewal for ${catalogTitle(c)}?`)) return;
        await engine.submit(SubmitActions.ssRenew, { id: c.id }, 6);
        await loadCaches();
      };

      const doTopup = async () => {
        if (!topupAmount.value || topupAmount.value < 10) {
          alert('Amount must be ≥ 10');
          return;
        }
        await engine.submit(SubmitActions.ssTopup, { amount: topupAmount.value }, 6);
        topupHint.value = 'Top-up requested — check payment link in ss_topup.json / account';
        await refreshBalances(true);
      };

      const doTopupCalc = async () => {
        try {
          const data = await ssApiGet<unknown>(`/profile/balance/calculate?amount=${topupAmount.value || 100}`);
          topupHint.value = `Calc: ${JSON.stringify(data || {}).slice(0, 220)}`;
        } catch (e: any) {
          topupHint.value = e?.response?.data?.message || e?.message || 'Calc failed';
        }
      };

      watch(editProtocol, () => {
        availableServers.value = [];
      });

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
        selectedDetailTag,
        channelLabel,
        locations,
        availableServers,
        protocols,
        editProtocol,
        editLocationId,
        editServerId,
        editDisableReality,
        editChangeSni,
        editUseXhttp,
        editUseGrpc,
        editAutoRenewal,
        editAutoRenewDays,
        autofitStatus,
        topupAmount,
        topupHint,
        infoModal,
        activeConfig,
        catalogTitle,
        catalogTag,
        catalogSourceLabel,
        formatExpiresAt,
        formatRub,
        isImported,
        importKey,
        selectConfig,
        saveKey,
        addKey,
        removeKey,
        syncCatalog,
        refreshBalances,
        importSelected,
        loadServers,
        applySettings,
        runAutofit,
        loadServerStats,
        loadTraffic,
        saveAutoRenewal,
        renewNow,
        doTopup,
        doTopupCalc
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
  .ss-row-active td {
    background: rgba(47, 111, 237, 0.12);
  }
  .ss-selected-title {
    font-weight: 600;
    margin-bottom: 4px;
  }
  .ss-panel {
    margin-top: 12px;
    padding-top: 8px;
    border-top: 1px solid rgba(160, 167, 167, 0.35);
  }
  .ss-panel-title {
    font-weight: 600;
    margin-bottom: 6px;
  }
  .ss-field {
    display: inline-block;
    margin: 4px 12px 4px 0;
    font-size: 12px;
  }
  .ss-check {
    display: inline-block;
    margin: 4px 12px 4px 0;
    font-size: 12px;
  }
  .ss-pre {
    margin-top: 6px;
    white-space: pre-wrap;
    font-size: 11px;
    color: #c9d1d9;
  }
</style>
