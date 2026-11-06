<!DOCTYPE html>
<html>
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge">
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Cache-Control" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">
<title>StealthSurf</title>
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">
<link rel="stylesheet" type="text/css" href="/js/table/table.css">
<script type="text/javascript" src="/js/jquery.js"></script>
<script type="text/javascript" src="/js/httpApi.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/validator.js"></script>
<style type="text/css">
  #Loading, #overDiv { z-index: 9999; }
  .FormTitle .formfonttitle { text-align: left; }
  .ss-section-tabs {
    margin: 8px 0 12px;
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
  }
  .ss-section-tabs .ss-tab {
    display: inline-block;
    padding: 4px 12px;
    margin: 0;
    border: 1px solid #6b757b;
    background: #4d595d;
    color: #fff;
    font-weight: bold;
    font-size: 12px;
    cursor: pointer;
    border-radius: 3px;
  }
  .ss-section-tabs .ss-tab:hover { background: #596e74; }
  .ss-section-tabs .ss-tab.active {
    background: #222;
    border-color: #fc0;
    color: #fc0;
  }
  .ss-panel { display: none; }
  .ss-panel.active { display: block; }
  .ss-hint {
    color: #ffcc00;
    font-size: 12px;
    margin: 6px 0;
  }
  .ss-hint.ok { color: #5df15d; }
  .ss-hint.err { color: #ff6b6b; }
  .ss-msg {
    min-height: 18px;
    margin: 10px 0 4px;
    color: #ffcc00;
    white-space: pre-wrap;
    font-size: 13px;
  }
  .ss-msg.ok { color: #5df15d; }
  .ss-msg.err { color: #ff6b6b; }
  .ss-logbox {
    background: #2f3a3e;
    border: 1px solid #6b757b;
    color: #fff;
    font-family: Consolas, "Courier New", monospace;
    font-size: 11px;
    max-height: 280px;
    overflow: auto;
    white-space: pre-wrap;
    padding: 8px;
    margin-top: 6px;
  }
  .ss-row-buttons { display: inline-flex; flex-wrap: wrap; gap: 4px; align-items: center; vertical-align: middle; }
  .ss-row-buttons .button_gen,
  .ss-row-buttons .button_gen_small { margin: 2px 0; }
  .FormTable td span.label {
    color: #fff;
    padding: 3px 6px;
    border-radius: 3px;
    margin: 2px 4px 2px 0;
    font-weight: bold;
    display: inline-block;
  }
  .FormTable td span.label-success { background-color: green; }
  .FormTable td span.label-error { background-color: red; }
  .FormTable td span.label-warning { background-color: #fc0; color: #333; }
  .FormTable td span.label-muted { background-color: #6b757b; }
  .FormTable input[type="text"],
  .FormTable input[type="password"],
  .FormTable select,
  .FormTable textarea {
    background: #596e74;
    border: 1px solid #929ea1;
    color: #fff;
    padding: 3px 6px;
  }
  .FormTable textarea {
    width: 98%;
    min-height: 100px;
    font-family: Consolas, "Courier New", monospace;
    font-size: 12px;
  }
  .FormTable input.input_25_table { width: 240px; }
  .FormTable input.input_32_table { width: 320px; }
  .FormTable input.input_15_table { width: 140px; }
  .FormTable code {
    background: #2f3a3e;
    padding: 1px 4px;
    border-radius: 2px;
    font-size: 11px;
  }
  #updateBanner {
    display: none;
    margin: 8px 0 12px;
    padding: 8px 10px;
    border: 1px solid #fc0;
    background: rgba(255, 204, 0, 0.12);
    color: #fc0;
    font-size: 13px;
  }
  #updateBanner.show {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    align-items: center;
    justify-content: space-between;
  }
  .ss-data-table { width: 100%; border-collapse: collapse; }
  .ss-data-table th,
  .ss-data-table td {
    border-bottom: 1px solid #6b757b;
    padding: 6px 4px;
    text-align: left;
    vertical-align: middle;
    font-size: 12px;
  }
  .ss-data-table th { color: #ffcc00; }
  .ss-opt-row label {
    display: inline-block;
    margin-right: 12px;
    color: #fff;
  }
  .ss-opt-row input[type="checkbox"] { vertical-align: middle; }
</style>
<script type="text/javascript">
/* Merlin addon settings blob — merge StealthSurf payload into this, never replace wholesale */
var custom_settings;
try {
  custom_settings = <% get_custom_settings(); %>;
} catch (e) {
  custom_settings = {};
}
if (!custom_settings || typeof custom_settings !== "object") custom_settings = {};

function initial() {
  try {
    if (typeof show_menu === "function") show_menu();
  } catch (e) {}
  var page = (location.pathname || "").replace(/^\//, "") || "user1.asp";
  var cur = document.getElementById("ss_current_page");
  var next = document.getElementById("ss_next_page");
  if (cur) cur.value = page;
  if (next) next.value = page;
}
</script>
</head>
<body onload="initial();" class="bg">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0" style="display:none"></iframe>

<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" id="ss_current_page" value="">
<input type="hidden" name="next_page" id="ss_next_page" value="">
<input type="hidden" name="group_id" value="">
<input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply">
<input type="hidden" name="action_wait" value="8">
<input type="hidden" name="first_time" value="">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get("preferred_lang"); %>">
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>">
<input type="hidden" name="amng_custom" id="ss_payload_field" value="">

<table class="content" align="center" cellpadding="0" cellspacing="0">
  <tr>
    <td width="17">&nbsp;</td>
    <td width="202" valign="top">
      <div id="mainMenu"></div>
      <div id="subMenu"></div>
    </td>
    <td valign="top">
      <div id="tabMenu" class="submenuBlock"></div>
      <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
        <tr>
          <td valign="top">
            <table width="760px" border="0" cellpadding="4" cellspacing="0" id="FormTitle" class="FormTitle">
              <tr bgcolor="#4D595D">
                <td valign="top">
                  <div>&nbsp;</div>
                  <div class="formfonttitle">StealthSurf UI <span id="titleVer"></span></div>
                  <div class="formfontdesc">
                    VPN-провайдер StealthSurf — каталог конфигов, transparent proxy, routing и политики устройств на роутере.
                    После изменений на сайте нажмите <b>Синхронизировать</b>.
                  </div>
                  <div style="margin:10px 0 10px 5px;" class="splitLine"></div>

                  <div id="updateBanner">
                    <div>
                      Доступна новая версия: <b id="bannerLatest">—</b>
                      (установлена <span id="bannerInstalled">—</span>)
                    </div>
                    <div class="ss-row-buttons">
                      <input id="btnBannerUpdate" class="button_gen button_gen_small" type="button" value="Установить обновление">
                    </div>
                  </div>

                  <table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                    <thead>
                      <tr><td colspan="2">Состояние сервиса</td></tr>
                    </thead>
                    <tbody>
                      <tr>
                        <th width="30%">Статус</th>
                        <td>
                          <span id="runState" class="label label-error">stopped</span>
                          <span id="activeCfg" class="label label-muted">active: —</span>
                          <span id="modePill" class="label label-muted">mode: —</span>
                          <span id="ports" class="label label-muted">ports: —</span>
                          <span id="defaultPill" class="label label-muted">default: —</span>
                          <span id="installedVer" class="label label-muted">версия: —</span>
                          <span id="latestVer" class="label label-muted">GitHub: —</span>
                          <span id="updatePill" class="label label-warning" style="display:none">есть обновление</span>
                        </td>
                      </tr>
                      <tr>
                        <th>Управление</th>
                        <td>
                          <span class="ss-row-buttons">
                            <input id="btnStart" class="button_gen button_gen_small" type="button" value="Старт">
                            <input id="btnStop" class="button_gen button_gen_small" type="button" value="Стоп">
                            <input id="btnRestart" class="button_gen button_gen_small" type="button" value="Рестарт">
                            <input id="btnSync" class="button_gen button_gen_small" type="button" value="Синхронизировать">
                            <input id="btnRefresh" class="button_gen button_gen_small" type="button" value="Обновить UI">
                            <input id="btnCheckUpdate" class="button_gen button_gen_small" type="button" value="Проверить версию">
                            <input id="btnUpdate" class="button_gen button_gen_small" type="button" value="Установить с GitHub" style="display:none">
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>

                  <div class="ss-section-tabs" id="ssTabs">
                    <button class="ss-tab active" data-tab="keys" type="button">Ключи / Sync</button>
                    <button class="ss-tab" data-tab="catalog" type="button">Мои подключения</button>
                    <button class="ss-tab" data-tab="routing" type="button">Routing</button>
                    <button class="ss-tab" data-tab="policies" type="button">Политики MAC</button>
                    <button class="ss-tab" data-tab="general" type="button">Режим / DNS</button>
                    <button class="ss-tab" data-tab="backup" type="button">Backup / Логи</button>
                    <button class="ss-tab" data-tab="diag" type="button">Диагностика</button>
                  </div>

                  <!-- Keys -->
                  <div class="ss-panel active" id="tab-keys">
                    <table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">API-ключи StealthSurf</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Добавить ключ</th>
                          <td>
                            <input id="apiKey" class="input_32_table" type="password" maxlength="128" placeholder="stlth_........_........................" autocomplete="off">
                            <input id="apiKeyLabel" class="input_15_table" type="text" maxlength="64" placeholder="метка (опц.)" style="margin-left:6px">
                            <span class="ss-row-buttons" style="margin-left:6px">
                              <input id="btnSaveKey" class="button_gen button_gen_small" type="button" value="Сохранить и проверить">
                              <input id="btnAddKey" class="button_gen button_gen_small" type="button" value="Добавить ещё ключ">
                            </span>
                            <div class="ss-hint">Можно хранить несколько ключей — sync соберёт конфиги со всех учёток в один каталог.</div>
                          </td>
                        </tr>
                        <tr>
                          <th>Сохранённые ключи</th>
                          <td>
                            <table class="ss-data-table">
                              <thead><tr><th>Метка</th><th>Ключ (хвост)</th><th></th></tr></thead>
                              <tbody id="keysTable"></tbody>
                            </table>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <!-- Catalog -->
                  <div class="ss-panel" id="tab-catalog">
                    <table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Каталог подключений</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Фильтр / default</th>
                          <td>
                            <input id="catalogFilter" class="input_25_table" type="text" placeholder="название / протокол / id">
                            <select id="defaultOutbound" class="input_15_table" style="margin-left:6px"></select>
                            <span class="ss-row-buttons" style="margin-left:6px">
                              <input id="btnSetDefault" class="button_gen button_gen_small" type="button" value="Назначить default">
                              <input id="btnRebuild" class="button_gen button_gen_small" type="button" value="Пересобрать Xray">
                            </span>
                          </td>
                        </tr>
                        <tr>
                          <th>Конфиги</th>
                          <td>
                            <table class="ss-data-table">
                              <thead>
                                <tr>
                                  <th>ID</th><th>Название</th><th>Протокол</th><th>Локация</th>
                                  <th>Online</th><th>Expires</th><th>Outbound</th><th></th>
                                </tr>
                              </thead>
                              <tbody id="configTable"></tbody>
                            </table>
                          </td>
                        </tr>
                        <tr>
                          <th>Смена location / protocol</th>
                          <td>
                            <div>
                              <select id="configSelect" class="input_32_table"></select>
                            </div>
                            <div style="margin-top:6px">
                              <select id="locationSelect" class="input_25_table"></select>
                              <select id="protocolSelect" class="input_25_table" style="margin-left:6px"></select>
                            </div>
                            <div class="ss-opt-row" style="margin-top:8px">
                              <label><input type="checkbox" id="optUseXhttp"> use_xhttp</label>
                              <label><input type="checkbox" id="optUseGrpc"> use_grpc</label>
                              <label><input type="checkbox" id="optUseWarp"> use_warp</label>
                              <label><input type="checkbox" id="optUseSalamander"> use_salamander</label>
                              <label><input type="checkbox" id="optDisableReality"> disable_reality</label>
                            </div>
                            <div class="ss-row-buttons" style="margin-top:8px">
                              <input id="btnUpdateSettings" class="button_gen button_gen_small" type="button" value="PATCH на StealthSurf">
                              <input id="btnApplySole" class="button_gen button_gen_small" type="button" value="Apply как единственный">
                            </div>
                            <div id="protoHint" class="ss-hint">После смены на сайте нажмите «Синхронизировать».</div>
                          </td>
                        </tr>
                        <tr>
                          <th>Сборные подписки</th>
                          <td>
                            <table class="ss-data-table">
                              <thead><tr><th>ID</th><th>Название</th><th>Статус</th></tr></thead>
                              <tbody id="subsTable"></tbody>
                            </table>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <!-- Routing -->
                  <div class="ss-panel" id="tab-routing">
                    <table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Правила: домен / geo → outbound</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Пресет</th>
                          <td>
                            <select id="presetSelect" class="input_25_table">
                              <option value="all-vpn">весь трафик → default VPN</option>
                              <option value="ru-direct">RU / private → direct</option>
                              <option value="streaming-split">стриминг → alt, остальное → default</option>
                              <option value="block-ads">block ads / malware</option>
                            </select>
                            <select id="presetDefault" class="input_15_table" title="default config id" style="margin-left:6px"></select>
                            <select id="presetAlt" class="input_15_table" title="alt config id" style="margin-left:6px"></select>
                            <input id="btnPreset" class="button_gen button_gen_small" type="button" value="Применить пресет" style="margin-left:6px">
                          </td>
                        </tr>
                        <tr>
                          <th>Правила JSON</th>
                          <td>
                            <textarea id="routingJson" spellcheck="false"></textarea>
                            <div class="ss-hint">
                              Типы: <code>domain</code>, <code>full</code>, <code>keyword</code>, <code>regexp</code>,
                              <code>geosite</code>, <code>geoip</code>, <code>ip</code>, <code>cidr</code>.
                              Поле <code>outbound</code>: <code>ss-101</code> / <code>direct</code> / <code>block</code>.
                            </div>
                            <div class="ss-row-buttons" style="margin-top:6px">
                              <input id="btnSaveRouting" class="button_gen button_gen_small" type="button" value="Сохранить routing + Apply">
                              <input id="btnGeodata" class="button_gen button_gen_small" type="button" value="Обновить geoip/geosite">
                            </div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <!-- Policies -->
                  <div class="ss-panel" id="tab-policies">
                    <table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Bypass / Redirect по MAC</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Правила</th>
                          <td>
                            <div class="ss-hint">Нет правил → весь LAN в VPN. Есть правила → нужен catch-all redirect, иначе «дыра».</div>
                            <label style="color:#fff">
                              <input id="policyCatchall" type="checkbox"> Catch-all redirect для остальных
                            </label>
                            <input id="btnLoadClients" class="button_gen button_gen_small" type="button" value="Загрузить устройства" style="margin-left:8px">
                          </td>
                        </tr>
                        <tr>
                          <th>Добавить</th>
                          <td>
                            <select id="clientSelect" class="input_25_table"></select>
                            <select id="policyMode" class="input_15_table" style="margin-left:6px">
                              <option value="bypass">bypass</option>
                              <option value="redirect">redirect</option>
                            </select>
                            <input id="policyPorts" class="input_15_table" type="text" placeholder="порты (опц.)" style="margin-left:6px">
                            <select id="policyProto" class="input_15_table" style="margin-left:6px">
                              <option value="tcp">tcp</option>
                              <option value="udp">udp</option>
                            </select>
                            <span class="ss-row-buttons" style="margin-left:6px">
                              <input id="btnAddPolicy" class="button_gen button_gen_small" type="button" value="Добавить">
                              <input id="btnSavePolicies" class="button_gen button_gen_small" type="button" value="Apply политики">
                            </span>
                          </td>
                        </tr>
                        <tr>
                          <th>Таблица</th>
                          <td>
                            <table class="ss-data-table">
                              <thead><tr><th>Mode</th><th>MAC</th><th>Имя</th><th>Ports</th><th>Proto</th><th></th></tr></thead>
                              <tbody id="policiesTable"></tbody>
                            </table>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <!-- General -->
                  <div class="ss-panel" id="tab-general">
                    <table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Режим transparent proxy и DNS</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Dataplane mode</th>
                          <td>
                            <select id="modeSelect" class="input_32_table">
                              <option value="proxy">proxy (только SOCKS/HTTP, без LAN hijack)</option>
                              <option value="redirect">redirect (TCP transparent)</option>
                              <option value="tproxy">tproxy (TCP+UDP, нужен xt_TPROXY)</option>
                            </select>
                            <input id="btnSetMode" class="button_gen button_gen_small" type="button" value="Применить режим" style="margin-left:6px">
                          </td>
                        </tr>
                        <tr>
                          <th>DNS mode</th>
                          <td>
                            <select id="dnsModeSelect" class="input_25_table">
                              <option value="OFF">OFF</option>
                              <option value="BYPASS">BYPASS (ipset bypass)</option>
                              <option value="REDIRECT">REDIRECT (hijack :53 → Xray)</option>
                            </select>
                            <input id="btnSetDns" class="button_gen button_gen_small" type="button" value="Применить DNS" style="margin-left:6px">
                          </td>
                        </tr>
                        <tr>
                          <th>Версия аддона</th>
                          <td>
                            <span id="verDetail" class="label label-muted">—</span>
                            <span class="ss-row-buttons" style="margin-left:6px">
                              <input id="btnCheckUpdate2" class="button_gen button_gen_small" type="button" value="Проверить на GitHub">
                              <input id="btnForceUpdate" class="button_gen button_gen_small" type="button" value="Установить latest с GitHub">
                            </span>
                            <div class="ss-hint">
                              CLI: <code>stealthsurf check-update</code> / <code>stealthsurf update</code>.
                              Автопроверка при открытии UI (если старше 6 ч) и каждые 12 часов (cron).
                            </div>
                          </td>
                        </tr>
                        <tr>
                          <th>Xray binary</th>
                          <td>
                            <input id="btnInstallXray" class="button_gen button_gen_small" type="button" value="Установить / найти Xray">
                            <div class="ss-hint">Backup и просмотр логов — вкладка <b>Backup / Логи</b>.</div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <!-- Backup -->
                  <div class="ss-panel" id="tab-backup">
                    <table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Backup конфигураций</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Создать</th>
                          <td>
                            <div class="ss-hint">
                              В архив: conf, routing, outbounds, policies, configs/keys, xray.json.
                              Ночной backup в 03:00. Файлы: <code>/opt/share/stealthsurf/backups/</code>
                            </div>
                            <input id="backupNote" class="input_25_table" type="text" placeholder="заметка (опц.)">
                            <span class="ss-row-buttons" style="margin-left:6px">
                              <input id="btnBackup" class="button_gen button_gen_small" type="button" value="Создать backup">
                              <input id="btnBackupList" class="button_gen button_gen_small" type="button" value="Обновить список">
                            </span>
                            <div id="backupStatus" class="ss-hint">Список загружается…</div>
                          </td>
                        </tr>
                        <tr>
                          <th>Список</th>
                          <td>
                            <table class="ss-data-table">
                              <thead><tr><th>Файл</th><th>Когда</th><th>Заметка</th><th>Версия</th><th></th></tr></thead>
                              <tbody id="backupsTable"></tbody>
                            </table>
                          </td>
                        </tr>
                        <tr>
                          <th>Логи аддона</th>
                          <td>
                            <select id="logKind" class="input_25_table">
                              <option value="activity">activity (действия)</option>
                              <option value="errors">errors</option>
                              <option value="devices">devices (IP/MAC)</option>
                              <option value="addon">addon</option>
                              <option value="access">xray access</option>
                              <option value="xray-error">xray error</option>
                            </select>
                            <span class="ss-row-buttons" style="margin-left:6px">
                              <input id="btnLogs" class="button_gen button_gen_small" type="button" value="Показать логи">
                              <input id="btnDevicesSnap" class="button_gen button_gen_small" type="button" value="Снимок устройств LAN">
                              <input id="btnClearLogs" class="button_gen button_gen_small" type="button" value="Очистить логи">
                            </span>
                            <div id="logMeta" class="ss-hint">Выберите тип лога и нажмите «Показать логи».</div>
                            <div id="logBox" class="ss-logbox">(логи ещё не загружены)</div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <!-- Diag -->
                  <div class="ss-panel" id="tab-diag">
                    <table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Диагностика</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Действия</th>
                          <td>
                            <span class="ss-row-buttons">
                              <input id="btnDiag" class="button_gen button_gen_small" type="button" value="Снять diag dump">
                              <input id="btnTestCfg" class="button_gen button_gen_small" type="button" value="Тест xray.json">
                              <input id="btnConnSocks" class="button_gen button_gen_small" type="button" value="IP через SOCKS">
                              <input id="btnConnDirect" class="button_gen button_gen_small" type="button" value="IP напрямую">
                            </span>
                            <div class="ss-hint">Логи и backup — на вкладке <b>Backup / Логи</b>.</div>
                          </td>
                        </tr>
                        <tr>
                          <th>Результат</th>
                          <td><div id="diagBox" class="ss-logbox">(пусто)</div></td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <div id="msg" class="ss-msg"></div>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </td>
    <td width="10" align="center" valign="top">&nbsp;</td>
  </tr>
</table>
</form>

<div id="footer"></div>
<script type="text/javascript" src="/ext/stealthsurf/app.js"></script>
</body>
</html>
