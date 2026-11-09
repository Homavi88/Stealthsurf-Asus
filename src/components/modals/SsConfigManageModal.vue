<template>
  <modal ref="modal" :title="modalTitle" width="760">
    <div class="formfontdesc ss-manage" v-if="config">
      <div class="ss-hint">
        {{ catalogTag(config) }} · id={{ config.id }} ·
        {{ catalogLocationLabel(config, locations) }} · server={{ config.server_id || '—' }}
      </div>

      <div class="ss-panel" v-if="(config._ss_source || 'config') === 'config'">
        <div class="ss-panel-title">Change settings (PATCH)</div>
        <label class="ss-field">
          Protocol
          <select v-model="editProtocol" class="input_option">
            <option v-for="p in protocols" :key="p" :value="p">{{ p }}</option>
          </select>
        </label>
        <label class="ss-field">
          Location
          <select v-model.number="editLocationId" class="input_option">
            <option v-for="loc in locations" :key="loc.id" :value="Number(loc.id)">
              {{ locationDisplayName(loc) || loc.id }}
            </option>
          </select>
        </label>
        <label class="ss-field">
          Server
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
        <input class="button_gen button_gen_small" type="button" value="Server stats" @click.prevent="$emit('stats', config)" />
        <input class="button_gen button_gen_small" type="button" value="Traffic" @click.prevent="$emit('traffic', config)" />
      </div>

      <div class="ss-panel" v-if="(config._ss_source || 'config') === 'config'">
        <div class="ss-panel-title">Billing</div>
        <label class="ss-check">
          <input type="checkbox" v-model="editAutoRenewal" /> auto-renewal
        </label>
        <input type="number" class="input_6_table" v-model.number="editAutoRenewDays" min="1" style="width: 60px" />
        days
        <input class="button_gen button_gen_small" type="button" value="Save renewal" @click.prevent="saveAutoRenewal" />
        <input class="button_gen button_gen_small" type="button" value="Renew now" @click.prevent="renewNow" />
      </div>
    </div>
  </modal>
</template>

<script lang="ts">
  import { computed, defineComponent, PropType, ref, watch } from 'vue';
  import Modal from '@main/Modal.vue';
  import engine, { SubmitActions } from '@/modules/Engine';
  import { ssApiGet } from '@/modules/StealthSurfApiClient';
  import {
    SS_PROTOCOLS,
    SsCatalogConfig,
    SsLocation,
    catalogLocationLabel,
    catalogTag,
    catalogTitle,
    locationDisplayName
  } from '@/modules/StealthSurfCatalog';

  interface AvailableServer {
    id: number;
    ip?: string;
    available_slots?: number;
  }

  export default defineComponent({
    name: 'SsConfigManageModal',
    components: { Modal },
    props: {
      locations: { type: Array as PropType<SsLocation[]>, default: () => [] }
    },
    emits: ['stats', 'traffic', 'updated'],
    setup(props, { emit }) {
      const modal = ref<{ show: () => void; close: () => void } | null>(null);
      const config = ref<SsCatalogConfig | null>(null);
      const protocols = SS_PROTOCOLS;
      const availableServers = ref<AvailableServer[]>([]);
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

      const modalTitle = computed(() => (config.value ? `Manage · ${catalogTitle(config.value)}` : 'Manage config'));

      const hydrate = (c: SsCatalogConfig) => {
        config.value = c;
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
        availableServers.value = [];
      };

      const show = (c: SsCatalogConfig) => {
        hydrate(c);
        modal.value?.show();
      };

      const loadServers = async () => {
        if (!config.value || editLocationId.value === '') return;
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
        const c = config.value;
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
        emit('updated');
      };

      const runAutofit = async () => {
        const c = config.value;
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
        emit('updated');
      };

      const saveAutoRenewal = async () => {
        const c = config.value;
        if (!c) return;
        await engine.submit(
          SubmitActions.ssAutoRenewal,
          { id: c.id, enabled: editAutoRenewal.value, days: editAutoRenewDays.value },
          4
        );
        emit('updated');
      };

      const renewNow = async () => {
        const c = config.value;
        if (!c) return;
        if (!confirm(`Request renewal for ${catalogTitle(c)}?`)) return;
        await engine.submit(SubmitActions.ssRenew, { id: c.id }, 6);
        emit('updated');
      };

      watch(
        () => editProtocol.value,
        () => {
          availableServers.value = [];
        }
      );

      return {
        modal,
        config,
        locations: computed(() => props.locations),
        protocols,
        availableServers,
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
        modalTitle,
        catalogTag,
        catalogLocationLabel,
        locationDisplayName,
        show,
        loadServers,
        applySettings,
        runAutofit,
        saveAutoRenewal,
        renewNow
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
  .ss-manage .button_gen_small {
    margin: 4px 4px 0 0;
  }
</style>
