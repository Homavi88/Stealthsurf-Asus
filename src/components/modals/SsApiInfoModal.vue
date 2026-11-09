<template>
  <modal ref="modal" :title="title" width="720">
    <div class="formfontdesc ss-info">
      <div v-if="loading" class="ss-info-loading">Loading…</div>
      <div v-else-if="error" class="ss-info-error">{{ error }}</div>
      <template v-else>
        <div class="ss-info-subtitle" v-if="subtitle">{{ subtitle }}</div>

        <template v-if="kind === 'stats' && stats">
          <table class="FormTable">
            <tbody>
              <tr>
                <th>Host</th>
                <td>{{ stats.host || '—' }}</td>
              </tr>
              <tr>
                <th>Status</th>
                <td>{{ stats.status || '—' }}</td>
              </tr>
              <tr>
                <th>Uptime</th>
                <td>{{ stats.uptime_days != null ? stats.uptime_days + ' days' : '—' }}</td>
              </tr>
              <tr>
                <th>CPU</th>
                <td>{{ stats.cpu_model || '—' }}</td>
              </tr>
            </tbody>
          </table>
          <div class="ss-info-section" v-if="stats.stats?.length">
            <div class="ss-info-section-title">Recent load</div>
            <table class="FormTable">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>CPU %</th>
                  <th>RAM %</th>
                  <th>Up Mbit/s</th>
                  <th>Down Mbit/s</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="(row, idx) in stats.stats.slice().reverse().slice(0, 14)" :key="idx">
                  <td>{{ row.date || '—' }}</td>
                  <td>{{ fmtNum(row.cpu) }}</td>
                  <td>{{ fmtNum(row.ram) }}</td>
                  <td>{{ fmtNum(row.up) }}</td>
                  <td>{{ fmtNum(row.down) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="ss-info-empty" v-else>No time-series points for this server.</div>
        </template>

        <template v-else-if="kind === 'traffic' && traffic">
          <table class="FormTable">
            <tbody>
              <tr>
                <th>Scope</th>
                <td>
                  {{ traffic.scope?.title || traffic.scope?.type || '—' }}
                  <span v-if="traffic.scope?.protocol"> · {{ traffic.scope.protocol }}</span>
                </td>
              </tr>
              <tr>
                <th>Total (range)</th>
                <td>{{ formatBytes(traffic.total_bytes) }}</td>
              </tr>
              <tr>
                <th>Days with data</th>
                <td>{{ traffic.points?.length || 0 }}</td>
              </tr>
            </tbody>
          </table>
          <div class="ss-info-section" v-if="traffic.points?.length">
            <div class="ss-info-section-title">Daily usage</div>
            <table class="FormTable">
              <thead>
                <tr>
                  <th>Day (UTC)</th>
                  <th>Traffic</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="(p, idx) in traffic.points.slice().reverse().slice(0, 31)" :key="idx">
                  <td>{{ fmtDay(p.start) }}</td>
                  <td>{{ formatBytes(p.total_bytes) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="ss-info-empty" v-else>No traffic points in the selected range.</div>
        </template>

        <div class="ss-info-empty" v-else>No data.</div>
      </template>
    </div>
  </modal>
</template>

<script lang="ts">
  import { defineComponent, ref } from 'vue';
  import Modal from '@main/Modal.vue';
  import {
    ServerStatsPayload,
    TrafficPayload,
    formatBytes,
    ssApiGet,
    statsPathForConfig,
    trafficQueryPath,
    trafficScopeForConfig
  } from '@/modules/StealthSurfApiClient';
  import { SsCatalogConfig, catalogTitle } from '@/modules/StealthSurfCatalog';

  export default defineComponent({
    name: 'SsApiInfoModal',
    components: { Modal },
    setup() {
      const modal = ref<{ show: () => void; close: () => void } | null>(null);
      const title = ref('StealthSurf');
      const subtitle = ref('');
      const kind = ref<'stats' | 'traffic'>('stats');
      const loading = ref(false);
      const error = ref('');
      const stats = ref<ServerStatsPayload>(null);
      const traffic = ref<TrafficPayload>(null);

      const fmtNum = (n: number | undefined) => (n == null || Number.isNaN(Number(n)) ? '—' : Number(n).toFixed(1));
      const fmtDay = (ts?: number) => {
        if (!ts) return '—';
        return new Date(ts * 1000).toISOString().slice(0, 10);
      };

      const reset = () => {
        loading.value = true;
        error.value = '';
        stats.value = null;
        traffic.value = null;
      };

      const showStats = async (c: SsCatalogConfig) => {
        kind.value = 'stats';
        title.value = `Server stats · ${catalogTitle(c)}`;
        subtitle.value = `id ${c.id}` + (c._ss_source && c._ss_source !== 'config' ? ` · ${c._ss_source}` : '');
        reset();
        modal.value?.show();
        try {
          const data = await ssApiGet<ServerStatsPayload>(statsPathForConfig(c));
          stats.value = data ?? null;
          if (!stats.value) error.value = 'API returned no stats for this server.';
        } catch (e: any) {
          error.value = e?.response?.data?.message || e?.message || 'Failed to load server stats';
        } finally {
          loading.value = false;
        }
      };

      const showTraffic = async (c: SsCatalogConfig) => {
        kind.value = 'traffic';
        title.value = `Traffic · ${catalogTitle(c)}`;
        const scope = trafficScopeForConfig(c);
        subtitle.value = `${scope.scope_type} #${scope.scope_id} · last 30 days`;
        reset();
        modal.value?.show();
        try {
          const path = trafficQueryPath(scope.scope_type, scope.scope_id, 'day', 30);
          const data = await ssApiGet<TrafficPayload>(path);
          traffic.value = data ?? null;
          if (!traffic.value) error.value = 'API returned no traffic data.';
        } catch (e: any) {
          error.value = e?.response?.data?.message || e?.message || 'Failed to load traffic';
        } finally {
          loading.value = false;
        }
      };

      return {
        modal,
        title,
        subtitle,
        kind,
        loading,
        error,
        stats,
        traffic,
        formatBytes,
        fmtNum,
        fmtDay,
        showStats,
        showTraffic
      };
    }
  });
</script>

<style scoped>
  .ss-info-loading,
  .ss-info-empty {
    color: #a0a7a7;
    padding: 12px 0;
  }
  .ss-info-error {
    color: #ffcc00;
    padding: 8px 0;
  }
  .ss-info-subtitle {
    color: #a0a7a7;
    font-size: 12px;
    margin-bottom: 10px;
  }
  .ss-info-section {
    margin-top: 14px;
  }
  .ss-info-section-title {
    font-weight: 600;
    margin-bottom: 6px;
  }
  .ss-info :deep(th) {
    width: 140px;
  }
</style>
