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
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: "Segoe UI", system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    padding: 16px;
  }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .sub { color: var(--muted); font-size: 13px; margin-bottom: 16px; }
  .row { display: flex; flex-wrap: wrap; gap: 8px; margin: 8px 0; align-items: center; }
  .panel {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 14px;
    margin-bottom: 12px;
  }
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
  button:disabled { opacity: 0.5; cursor: default; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid var(--border); }
  .pill {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: 11px;
    background: #2a3542;
  }
  .pill.on { background: rgba(61,214,140,.15); color: var(--ok); }
  .pill.off { background: rgba(240,113,120,.15); color: var(--bad); }
  #msg { min-height: 18px; font-size: 13px; color: var(--muted); margin-top: 8px; }
  #msg.err { color: var(--bad); }
  #msg.ok { color: var(--ok); }
</style>
</head>
<body>
  <h1>StealthSurf</h1>
  <div class="sub">VPN-провайдер StealthSurf · управление на роутере через API-ключ</div>

  <div class="panel">
    <div class="row">
      <span id="runState" class="pill off">stopped</span>
      <span id="activeCfg" class="pill">active: —</span>
      <span id="ports" class="pill">socks/http: —</span>
    </div>
    <div class="row">
      <button id="btnStart" type="button">Старт</button>
      <button id="btnStop" class="secondary" type="button">Стоп</button>
      <button id="btnRestart" class="secondary" type="button">Рестарт</button>
      <button id="btnSync" type="button">Синхронизировать</button>
    </div>
  </div>

  <div class="panel">
    <label for="apiKey">API-ключ StealthSurf</label>
    <input id="apiKey" type="password" placeholder="stlth_........_........................" autocomplete="off">
    <div class="row">
      <button id="btnSaveKey" type="button">Сохранить и проверить</button>
    </div>
  </div>

  <div class="panel">
    <label for="configSelect">Конфигурация</label>
    <select id="configSelect"></select>
    <div class="row" style="margin-top:10px">
      <div style="flex:1; min-width:160px">
        <label for="locationSelect">Локация</label>
        <select id="locationSelect"></select>
      </div>
      <div style="flex:1; min-width:160px">
        <label for="protocolSelect">Протокол</label>
        <select id="protocolSelect">
          <option value="vless">vless</option>
          <option value="vless-2410">vless-2410</option>
          <option value="trojan">trojan</option>
          <option value="trojan-2901">trojan-2901</option>
          <option value="shadowsocks-2022">shadowsocks-2022</option>
          <option value="hysteria2">hysteria2 (позже)</option>
          <option value="wg">wg (позже)</option>
          <option value="amnezia-wg-2">amnezia-wg-2 (позже)</option>
        </select>
      </div>
    </div>
    <div class="row">
      <button id="btnUpdateSettings" class="secondary" type="button">Сменить на стороне StealthSurf</button>
      <button id="btnApply" type="button">Применить на роутере</button>
    </div>
  </div>

  <div class="panel">
    <table>
      <thead>
        <tr><th>ID</th><th>Название</th><th>Протокол</th><th>Локация</th><th>Online</th></tr>
      </thead>
      <tbody id="configTable"></tbody>
    </table>
  </div>

  <div class="row">
    <button id="btnRefresh" class="secondary" type="button">Обновить статус</button>
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
