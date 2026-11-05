<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Cache-Control" content="no-cache">
<title>StealthSurf</title>
<style>
  :root {
    --bg: #0f1419;
    --panel: #1a222c;
    --text: #e7ecf1;
    --muted: #8b9aab;
    --accent: #3d8bfd;
    --ok: #3dd68c;
    --bad: #f07178;
    --border: #2a3542;
    --warn: #e6c07b;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: "Segoe UI", system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    padding: 16px;
    max-width: 1100px;
  }
  h1 { font-size: 20px; margin: 0 0 4px; }
  h2 { font-size: 15px; margin: 0 0 10px; font-weight: 600; }
  .sub { color: var(--muted); font-size: 13px; margin-bottom: 16px; }
  .row { display: flex; flex-wrap: wrap; gap: 8px; margin: 8px 0; align-items: center; }
  .tabs { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 12px; }
  .tab {
    background: #2a3542; color: var(--text); border: 0; border-radius: 6px;
    padding: 7px 12px; cursor: pointer; font-weight: 600; font-size: 13px;
  }
  .tab.active { background: var(--accent); }
  .panel {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 14px;
    margin-bottom: 12px;
    display: none;
  }
  .panel.active { display: block; }
  label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 4px; }
  input, select, textarea {
    width: 100%;
    max-width: 520px;
    background: var(--bg);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 8px 10px;
  }
  textarea { min-height: 90px; font-family: ui-monospace, monospace; font-size: 12px; max-width: 100%; }
  button {
    background: var(--accent);
    color: #fff;
    border: 0;
    border-radius: 6px;
    padding: 8px 14px;
    cursor: pointer;
    font-weight: 600;
  }
  button.secondary { background: #2a3542; }
  button.danger { background: var(--bad); }
  button.small { padding: 4px 8px; font-size: 12px; }
  button:disabled { opacity: 0.5; cursor: default; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid var(--border); vertical-align: top; }
  .pill {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: 11px;
    background: #2a3542;
  }
  .pill.on { background: rgba(61,214,140,.15); color: var(--ok); }
  .pill.off { background: rgba(240,113,120,.15); color: var(--bad); }
  .pill.warn { background: rgba(230,192,123,.15); color: var(--warn); }
  .pill.update {
    background: rgba(230,192,123,.2);
    color: var(--warn);
    border: 1px solid rgba(230,192,123,.45);
    font-weight: 700;
  }
  #msg { min-height: 18px; font-size: 13px; color: var(--muted); margin-top: 8px; white-space: pre-wrap; }
  #msg.err { color: var(--bad); }
  #msg.ok { color: var(--ok); }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 800px) { .grid2 { grid-template-columns: 1fr; } }
  .hint { font-size: 12px; color: var(--muted); margin-top: 6px; }
  code { font-size: 12px; background: #0b1015; padding: 1px 4px; border-radius: 4px; }
  .logbox {
    background: #0b1015; border: 1px solid var(--border); border-radius: 6px;
    padding: 10px; font-family: ui-monospace, monospace; font-size: 11px;
    max-height: 280px; overflow: auto; white-space: pre-wrap;
  }
  .header-row {
    display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px;
    align-items: flex-start; margin-bottom: 12px;
  }
  .controls-bar {
    display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
    padding: 10px 12px; background: #121920; border: 1px solid var(--border);
    border-radius: 8px; margin-bottom: 10px;
  }
  .controls-bar .label {
    font-size: 12px; color: var(--muted); margin-right: 4px; text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  button.success { background: #2f9e6b; }
  button.warn { background: #b8892d; color: #111; }
  #updateBanner {
    display: none; margin: 0 0 12px; padding: 10px 12px;
    border-radius: 8px; border: 1px solid rgba(230,192,123,.5);
    background: rgba(230,192,123,.12); color: var(--warn); font-size: 13px;
  }
  #updateBanner.show { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; }
  #updateBanner strong { color: #f0d78c; }
</style>
</head>
<body>
  <div class="header-row">
    <div>
      <h1>StealthSurf</h1>
      <div class="sub">VPN-провайдер StealthSurf · каталог конфигов, transparent proxy, routing и политики на роутере</div>
    </div>
    <div class="row" style="margin:0; justify-content:flex-end">
      <span id="installedVer" class="pill">версия: —</span>
      <span id="latestVer" class="pill">GitHub: —</span>
      <span id="updatePill" class="pill" style="display:none">есть обновление</span>
    </div>
  </div>

  <div id="updateBanner">
    <div>
      Доступна новая версия: <strong id="bannerLatest">—</strong>
      (установлена <span id="bannerInstalled">—</span>)
    </div>
    <div class="row" style="margin:0">
      <button id="btnBannerUpdate" class="warn" type="button">Установить обновление</button>
    </div>
  </div>

  <div class="controls-bar">
    <span class="label">Аддон</span>
    <button id="btnStart" class="success" type="button">Старт</button>
    <button id="btnStop" class="danger" type="button">Стоп</button>
    <button id="btnRestart" type="button">Рестарт</button>
    <span style="width:1px; height:22px; background:var(--border); margin:0 4px"></span>
    <button id="btnSync" type="button">Синхронизировать</button>
    <button id="btnRefresh" class="secondary" type="button">Обновить UI</button>
    <button id="btnCheckUpdate" class="secondary" type="button">Проверить версию</button>
    <button id="btnUpdate" class="warn" type="button" style="display:none">Установить с GitHub</button>
  </div>

  <div class="panel active" id="statusBar" style="display:block">
    <div class="row">
      <span id="runState" class="pill off">stopped</span>
      <span id="activeCfg" class="pill">active: —</span>
      <span id="modePill" class="pill">mode: —</span>
      <span id="ports" class="pill">ports: —</span>
      <span id="defaultPill" class="pill">default: —</span>
    </div>
  </div>

  <div class="tabs">
    <button class="tab active" data-tab="keys" type="button">Ключи / Sync</button>
    <button class="tab" data-tab="catalog" type="button">Мои подключения</button>
    <button class="tab" data-tab="routing" type="button">Routing</button>
    <button class="tab" data-tab="policies" type="button">Политики MAC</button>
    <button class="tab" data-tab="general" type="button">Режим / DNS</button>
    <button class="tab" data-tab="diag" type="button">Диагностика</button>
  </div>

  <div class="panel active" id="tab-keys">
    <h2>API-ключи StealthSurf</h2>
    <label for="apiKey">Добавить ключ</label>
    <input id="apiKey" type="password" placeholder="stlth_........_........................" autocomplete="off">
    <div class="row">
      <input id="apiKeyLabel" placeholder="метка (опционально)" style="max-width:200px">
      <button id="btnSaveKey" type="button">Сохранить и проверить</button>
      <button id="btnAddKey" class="secondary" type="button">Добавить ещё ключ</button>
    </div>
    <div class="hint">Можно хранить несколько ключей — sync соберёт конфиги со всех учёток в один каталог.</div>
    <table style="margin-top:12px">
      <thead><tr><th>Метка</th><th>Ключ (хвост)</th><th></th></tr></thead>
      <tbody id="keysTable"></tbody>
    </table>
  </div>

  <div class="panel" id="tab-catalog">
    <h2>Каталог подключений</h2>
    <div class="row">
      <input id="catalogFilter" placeholder="Фильтр по названию / протоколу / id" style="max-width:320px">
      <label style="display:inline; margin:0">Default outbound</label>
      <select id="defaultOutbound" style="max-width:220px"></select>
      <button id="btnSetDefault" class="secondary" type="button">Назначить default</button>
      <button id="btnRebuild" type="button">Пересобрать Xray</button>
    </div>
    <table>
      <thead>
        <tr>
          <th>ID</th><th>Название</th><th>Протокол</th><th>Локация</th>
          <th>Online</th><th>Expires</th><th>Outbound</th><th>Действия</th>
        </tr>
      </thead>
      <tbody id="configTable"></tbody>
    </table>

    <div class="grid2" style="margin-top:14px">
      <div>
        <h2>Смена location / protocol (API)</h2>
        <label for="configSelect">Конфиг</label>
        <select id="configSelect"></select>
        <div class="row" style="margin-top:8px">
          <div style="flex:1; min-width:140px">
            <label for="locationSelect">Локация</label>
            <select id="locationSelect"></select>
          </div>
          <div style="flex:1; min-width:140px">
            <label for="protocolSelect">Протокол</label>
            <select id="protocolSelect"></select>
          </div>
        </div>
        <div class="row">
          <button id="btnUpdateSettings" class="secondary" type="button">PATCH на StealthSurf</button>
          <button id="btnApplySole" type="button">Apply как единственный</button>
        </div>
        <div id="protoHint" class="hint"></div>
      </div>
      <div>
        <h2>Сборные подписки</h2>
        <table>
          <thead><tr><th>ID</th><th>Название</th><th>Статус</th></tr></thead>
          <tbody id="subsTable"></tbody>
        </table>
      </div>
    </div>
  </div>

  <div class="panel" id="tab-routing">
    <h2>Правила: домен / geo → outbound</h2>
    <div class="row">
      <select id="presetSelect" style="max-width:220px">
        <option value="all-vpn">весь трафик → default VPN</option>
        <option value="ru-direct">RU / private → direct</option>
        <option value="streaming-split">стриминг → alt, остальное → default</option>
        <option value="block-ads">block ads / malware</option>
      </select>
      <select id="presetDefault" style="max-width:160px" title="default config id"></select>
      <select id="presetAlt" style="max-width:160px" title="alt config id"></select>
      <button id="btnPreset" type="button">Применить пресет</button>
    </div>
    <label for="routingJson">Правила JSON (matcher → ss-&lt;id&gt; | direct | block)</label>
    <textarea id="routingJson" spellcheck="false"></textarea>
    <div class="hint">Типы: <code>domain</code>, <code>full</code>, <code>keyword</code>, <code>regexp</code>, <code>geosite</code>, <code>geoip</code>, <code>ip</code>, <code>cidr</code>. Поле <code>outbound</code>: <code>ss-101</code> / <code>direct</code> / <code>block</code>.</div>
    <div class="row">
      <button id="btnSaveRouting" type="button">Сохранить routing + Apply</button>
      <button id="btnGeodata" class="secondary" type="button">Обновить geoip/geosite</button>
    </div>
  </div>

  <div class="panel" id="tab-policies">
    <h2>Bypass / Redirect по MAC</h2>
    <div class="hint">Нет правил → весь LAN в VPN. Есть правила → нужен catch-all redirect (флаг ниже), иначе «дыра».</div>
    <div class="row">
      <label style="display:flex; align-items:center; gap:6px; margin:0">
        <input id="policyCatchall" type="checkbox" style="width:auto; max-width:none"> Catch-all redirect для остальных
      </label>
      <button id="btnLoadClients" class="secondary" type="button">Загрузить устройства</button>
    </div>
    <div class="row">
      <select id="clientSelect" style="max-width:280px"></select>
      <select id="policyMode" style="max-width:140px">
        <option value="bypass">bypass</option>
        <option value="redirect">redirect</option>
      </select>
      <input id="policyPorts" placeholder="порты (опц. 443,80)" style="max-width:160px">
      <select id="policyProto" style="max-width:100px">
        <option value="tcp">tcp</option>
        <option value="udp">udp</option>
      </select>
      <button id="btnAddPolicy" type="button">Добавить</button>
      <button id="btnSavePolicies" type="button">Apply политики</button>
    </div>
    <table>
      <thead><tr><th>Mode</th><th>MAC</th><th>Имя</th><th>Ports</th><th>Proto</th><th></th></tr></thead>
      <tbody id="policiesTable"></tbody>
    </table>
  </div>

  <div class="panel" id="tab-general">
    <h2>Режим transparent proxy и DNS</h2>
    <div class="grid2">
      <div>
        <label for="modeSelect">Dataplane mode</label>
        <select id="modeSelect">
          <option value="proxy">proxy (только SOCKS/HTTP, без LAN hijack)</option>
          <option value="redirect">redirect (TCP transparent, шире совместимость)</option>
          <option value="tproxy">tproxy (TCP+UDP, нужен xt_TPROXY)</option>
        </select>
        <div class="row"><button id="btnSetMode" type="button">Применить режим</button></div>
      </div>
      <div>
        <label for="dnsModeSelect">DNS mode</label>
        <select id="dnsModeSelect">
          <option value="OFF">OFF</option>
          <option value="BYPASS">BYPASS (ipset bypass)</option>
          <option value="REDIRECT">REDIRECT (hijack :53 → Xray)</option>
        </select>
        <div class="row"><button id="btnSetDns" type="button">Применить DNS</button></div>
      </div>
    </div>
    <h2 style="margin-top:16px">Версия аддона</h2>
    <div class="row">
      <span id="verDetail" class="pill">—</span>
      <button id="btnCheckUpdate2" class="secondary" type="button">Проверить на GitHub</button>
      <button id="btnForceUpdate" class="warn" type="button">Установить latest с GitHub</button>
    </div>
    <div class="hint">Автопроверка при открытии UI и каждые 12 часов (cron). Подсветка, если latest &gt; установленной.</div>

    <div class="row" style="margin-top:12px">
      <button id="btnInstallXray" class="secondary" type="button">Установить / найти Xray</button>
    </div>

    <h2 style="margin-top:16px">Backup конфигураций</h2>
    <div class="hint">Сохраняет conf, routing, outbounds, policies (с IP устройств), configs, xray.json. Ночной backup в 03:00. Авто-backup перед apply / restore / сменой режима.</div>
    <div class="row">
      <input id="backupNote" placeholder="заметка (опц.)" style="max-width:200px">
      <button id="btnBackup" type="button">Создать backup</button>
      <button id="btnBackupList" class="secondary" type="button">Обновить список</button>
    </div>
    <table>
      <thead><tr><th>Файл</th><th>Когда</th><th>Заметка</th><th></th></tr></thead>
      <tbody id="backupsTable"></tbody>
    </table>
  </div>

  <div class="panel" id="tab-diag">
    <h2>Диагностика и логи</h2>
    <div class="row">
      <button id="btnDiag" type="button">Снять diag dump</button>
      <button id="btnTestCfg" class="secondary" type="button">Тест xray.json</button>
      <button id="btnConnSocks" class="secondary" type="button">IP через SOCKS</button>
      <button id="btnConnDirect" class="secondary" type="button">IP напрямую</button>
    </div>
    <div class="row">
      <select id="logKind" style="max-width:160px">
        <option value="activity">activity (действия)</option>
        <option value="errors">errors</option>
        <option value="devices">devices (IP/MAC)</option>
        <option value="addon">addon</option>
        <option value="access">xray access</option>
        <option value="xray-error">xray error</option>
      </select>
      <button id="btnLogs" type="button">Показать логи</button>
      <button id="btnDevicesSnap" class="secondary" type="button">Снимок устройств LAN</button>
      <button id="btnClearLogs" class="danger" type="button">Очистить логи</button>
    </div>
    <div class="hint">Activity-лог пишет действия аддона и IP устройств при политиках / start / firewall.</div>
    <div id="diagBox" class="logbox">(пусто)</div>
  </div>

  <div id="msg"></div>

  <form method="POST" name="form" id="hidden_action_form" action="/start_apply.htm" target="hidden_frame" style="display:none">
    <input type="hidden" name="action_mode" value="apply">
    <input type="hidden" name="action_script" value="">
    <input type="hidden" name="action_wait" value="8">
    <input type="hidden" name="current_page" value="">
    <input type="hidden" name="next_page" value="">
    <input type="hidden" name="amng_custom" id="ss_payload_field" value="">
  </form>
  <iframe name="hidden_frame" id="hidden_frame" width="0" height="0" style="display:none"></iframe>

  <script src="/ext/stealthsurf/app.js"></script>
</body>
</html>
