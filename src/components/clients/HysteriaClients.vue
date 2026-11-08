<template>
  <table class="FormTable SettingsTable tableApi_table" v-if="clients">
    <thead>
      <tr>
        <td colspan="4">Clients</td>
      </tr>
    </thead>
    <tbody>
      <tr class="row_title">
        <th>Auth</th>
        <th>Email</th>
        <th style="min-width: 120px"></th>
      </tr>
      <tr class="row_title">
        <td>
          <input v-model="newClient.auth" class="input_25_table" placeholder="Auth string" />
        </td>
        <td>
          <input v-model="newClient.email" class="input_25_table" placeholder="Email" />
        </td>
        <td>
          <button class="add_btn" @click.prevent="addClient"></button>
        </td>
      </tr>
      <tr v-if="!clients.length" class="data_tr">
        <td colspan="3" style="color: #ffcc00">No clients registered</td>
      </tr>
      <tr v-for="(client, index) in clients" :key="index" class="data_tr">
        <td>{{ client.auth }}</td>
        <td>{{ client.email }}</td>
        <td>
          <qr :client="client" :proxy="proxy"></qr>
          <button @click.prevent="editClient(client, index)" class="button_gen button_gen_small">&#8494;</button>
          <button @click.prevent="removeClient(client)" class="button_gen button_gen_small">&#10005;</button>
        </td>
      </tr>
    </tbody>
  </table>
</template>

<script lang="ts">
  import { XrayHysteriaClientObject } from '@/modules/ClientsObjects';
  import { defineComponent, ref } from 'vue';
  import engine from '@/modules/Engine';
  import Qr from './QrCodeClient.vue';

  export default defineComponent({
    name: 'HysteriaClients',
    components: {
      Qr
    },
    props: {
      clients: Array<XrayHysteriaClientObject>,
      proxy: {
        type: Object as () => any,
        required: true
      }
    },
    setup(props) {
      const editingIndex = ref<number | null>(null);
      const clients = ref<XrayHysteriaClientObject[]>(props.clients ?? []);
      const newClient = ref<XrayHysteriaClientObject>(new XrayHysteriaClientObject());
      newClient.value.auth = engine.uuid();

      const resetNewForm = () => {
        newClient.value.auth = engine.uuid();
        newClient.value.email = '';
      };

      const removeClient = (client: XrayHysteriaClientObject) => {
        if (!confirm('Are you sure you want to remove this client?')) return;
        clients.value.splice(clients.value.indexOf(client), 1);
      };

      const addClient = () => {
        let client = new XrayHysteriaClientObject();
        client.auth = newClient.value.auth;
        client.email = newClient.value.email;
        if (!client.auth) {
          alert('Auth is required');
          return;
        }
        clients.value.push(client);
        resetNewForm();
      };

      const editClient = (client: XrayHysteriaClientObject, index: number) => {
        newClient.value.auth = client.auth;
        newClient.value.email = client.email;
        editingIndex.value = index;
        clients.value.splice(clients.value.indexOf(client), 1);
      };

      return {
        clients,
        newClient,
        addClient,
        editClient,
        removeClient
      };
    }
  });
</script>
