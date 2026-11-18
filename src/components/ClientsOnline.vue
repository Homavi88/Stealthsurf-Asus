<template>
  <div class="formfontdesc" v-if="enable_check()">
    <table class="FormTable SettingsTable tableApi_table">
      <thead>
        <tr>
          <td colspan="4">{{ $t('com.ClientsOnline.title') }}</td>
        </tr>
      </thead>
      <tbody>
        <tr class="row_title">
          <th>{{ $t('com.ClientsOnline.label_ip') }}</th>
          <th>Name</th>
          <th>MAC</th>
          <th>{{ $t('com.ClientsOnline.label_client') }}</th>
        </tr>
        <tr v-for="client in clients" :key="clientKey(client)" class="data_tr">
          <td>
            <span class="label label-success">{{ $t('com.ClientsOnline.online') }}</span>
            <span class="ss-mono">{{ client.ip || '—' }}</span>
          </td>
          <td>{{ displayName(client) }}</td>
          <td class="ss-mono">{{ client.mac || '—' }}</td>
          <td>
            <span v-if="client.outbound" class="ss-mono">{{ client.outbound }}</span>
            <span v-if="client.email?.length"> {{ client.email.filter(Boolean).join(', ') }}</span>
          </td>
        </tr>
        <tr v-if="!clients.length" class="data_tr">
          <td colspan="4" style="color: #ffcc00">{{ $t('com.ClientsOnline.noone_is_online') }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<script lang="ts">
  import { defineComponent, ref, onMounted, onBeforeUnmount } from 'vue';
  import engine, { SubmitActions } from '@/modules/Engine';
  import { createPoller } from '@/modules/Polling';

  interface Client {
    ip: string;
    mac?: string;
    name?: string;
    outbound?: string;
    last_seen?: string;
    email: string[];
  }

  export default defineComponent({
    name: 'ClientsOnline',
    setup() {
      const clients = ref<Client[]>([]);

      // Always poll — transparent LAN VPN devices come from access log, not only inbound users.
      const enable_check = () => true;

      const fetchClients = async () => {
        try {
          const response = await engine.getWebData<Client[]>('clients-online');
          const data = Array.isArray(response.data) ? response.data : [];
          clients.value = data.map((c) => ({
            ip: c.ip || '',
            mac: c.mac || '',
            name: c.name || '',
            outbound: c.outbound || '',
            last_seen: c.last_seen || '',
            email: Array.isArray(c.email) ? c.email : []
          }));
        } catch (error) {
          console.warn('Error fetching clients:', error);
        }
      };

      const displayName = (c: Client) => c.name || c.email?.filter(Boolean).join(', ') || '—';
      const clientKey = (c: Client) => `${c.ip}|${c.mac}|${(c.email || []).join(',')}`;

      const clientsPoller = createPoller(async () => {
        if (!enable_check()) return;
        await engine.submit(SubmitActions.clientsOnline);
        await fetchClients();
      }, 4000);

      onMounted(() => {
        clientsPoller.start();
      });

      onBeforeUnmount(() => {
        clientsPoller.stop();
      });

      return {
        clients,
        enable_check,
        displayName,
        clientKey
      };
    }
  });
</script>
