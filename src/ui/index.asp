<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<html xmlns:v>
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Cache-Control" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">
<title>StealthSurf</title>
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">
<link rel="stylesheet" type="text/css" href="menu_style.css">
<link rel="stylesheet" type="text/css" href="/js/table/table.css">
<script type="text/javascript" src="/js/jquery.js"></script>
<script type="text/javascript" src="/js/httpApi.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/validator.js"></script>
<!-- custom_settings outside of try/catch — a broken ASP inject must not kill show_menu() -->
<xmp id="ss_custom_settings_data" hidden><% get_custom_settings(); %></xmp>
<script type="text/javascript">
var custom_settings = {};
(function () {
  try {
    var raw = document.getElementById("ss_custom_settings_data");
    if (!raw) return;
    var txt = (raw.textContent || raw.innerText || "").replace(/^\s+|\s+$/g, "");
    if (!txt || txt.charAt(0) === "<") return;
    custom_settings = JSON.parse(txt);
    if (!custom_settings || typeof custom_settings !== "object") custom_settings = {};
  } catch (e) {
    custom_settings = {};
  }
})();

function ss_page_name() {
  var p = (location.pathname || "").replace(/^\//, "");
  return p || "user1.asp";
}

function initial() {
  var page = ss_page_name();
  // show_menu() reads form.current_page to pick the active Merlin section/tab
  if (document.form) {
    if (document.form.current_page) document.form.current_page.value = page;
    if (document.form.next_page) document.form.next_page.value = page;
  }
  if (typeof show_menu === "function") {
    show_menu();
  }
}
</script>
<style type="text/css">
  /* Layout/buttons aligned with XrayUI (Asuswrt-Merlin FormTable patterns) */
  #Loading, #overDiv { z-index: 9999; }
  .FormTitle { position: relative; }
  .FormTitle .formfonttitle { text-align: left; }
  .formfontdesc { margin-left: 0; }
  .ss-panel { display: block; margin: 0; }
  .ss-section-tabs { display: none !important; }
  .ss-hint {
    color: #fc0;
    font-size: 12px;
    margin: 6px 0;
  }
  .ss-hint.ok { color: #5df15d; }
  .ss-hint.err { color: #ff6b6b; }
  .ss-msg {
    min-height: 18px;
    margin: 10px 0 4px;
    color: #fc0;
    white-space: pre-wrap;
    font-size: 13px;
  }
  .ss-msg.ok { color: #5df15d; }
  .ss-msg.err { color: #ff6b6b; }
  .ss-logbox {
    background: #2f3a3e;
    border: 1px solid #6b757b;
    color: #fff;
    font-family: "Courier New", Courier, monospace;
    font-size: 11px;
    max-height: 280px;
    overflow: auto;
    white-space: pre-wrap;
    padding: 8px;
    margin-top: 6px;
  }
  .FormTable {
    margin-bottom: 14px;
  }
  .FormTable td,
  .FormTable th {
    vertical-align: middle;
  }
  .FormTable td span.label {
    color: #fff;
    padding: 3px 5px;
    border-radius: 4px;
    margin: 4px 4px 0 0;
    font-weight: bold;
    display: inline-block;
  }
  .FormTable td span.label-success { background-color: green; }
  .FormTable td span.label-error { background-color: red; }
  .FormTable td span.label-warning { background-color: #fc0; color: #596e74; }
  .FormTable td span.label-muted { background-color: #6b757b; }
  .FormTable input[type="text"],
  .FormTable input[type="password"],
  .FormTable input[type="number"],
  .FormTable select,
  .FormTable textarea {
    background: #596e74;
    border: 1px solid #929ea1;
    color: #fff;
    padding: 3px 6px;
    outline: none;
  }
  .FormTable input::placeholder,
  .FormTable textarea::placeholder {
    color: #fc0;
    font-weight: bold;
    opacity: 0.5;
    font-style: italic;
  }
  .FormTable textarea {
    width: 98%;
    min-height: 100px;
    font-family: "Courier New", Courier, monospace;
    font-size: 13px;
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
  .row-buttons,
  .ss-row-buttons {
    float: right;
  }
  .row-buttons label,
  .ss-row-buttons label {
    margin-right: 10px;
    vertical-align: middle;
  }
  .button_gen_small {
    min-width: auto !important;
    border-radius: 4px !important;
    padding: 3px 5px 5px 5px !important;
    margin: 2px !important;
    font-weight: normal !important;
    height: auto !important;
    font-size: 11px !important;
    color: #fff !important;
    text-decoration: none !important;
  }
  .button_info {
    background: #fc0 !important;
    color: #333 !important;
    font-weight: bold !important;
    border-radius: 10px !important;
    padding: 3px 8px 5px 8px !important;
  }
  .apply_gen {
    margin: 12px 0 10px;
    text-align: center;
  }
  .apply_gen .button_gen {
    min-width: 120px;
  }
  .ss-version {
    padding-top: 10px;
    min-height: 22px;
    position: relative;
  }
  .ss-version a {
    text-decoration: underline;
    font-size: 10px;
    color: #fc0;
    font-weight: bold;
    position: absolute;
    bottom: 0;
    right: 5px;
  }
  .ss-meta-inline {
    color: #cfd8dc;
    font-size: 12px;
  }
  .ss-core-ver {
    float: right;
    color: #fc0;
    font-weight: bold;
    font-size: 12px;
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
  .ss-modal {
    display: none;
    position: fixed;
    z-index: 10050;
    left: 0; top: 0; right: 0; bottom: 0;
    background: rgba(0, 0, 0, 0.55);
    align-items: center;
    justify-content: center;
    padding: 16px;
  }
  .ss-modal.show { display: flex; }
  .ss-modal-card {
    width: min(560px, 96vw);
    max-height: 86vh;
    overflow: auto;
    background: #4d595d;
    border: 1px solid #fc0;
    color: #fff;
    padding: 14px 16px 12px;
    box-shadow: 0 8px 28px rgba(0,0,0,0.45);
  }
  .ss-modal-card.ss-settings-card {
    width: min(640px, 96vw);
  }
  .ss-settings-grid {
    display: grid;
    grid-template-columns: 1fr;
    gap: 10px;
  }
  .ss-settings-row {
    display: flex;
    flex-wrap: wrap;
    gap: 8px 12px;
    align-items: center;
  }
  .ss-settings-row label.ss-check {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 13px;
    color: #fff;
    cursor: pointer;
  }
  .ss-settings-field {
    display: flex;
    flex-direction: column;
    gap: 4px;
    flex: 1 1 220px;
    min-width: 180px;
  }
  .ss-settings-field > span {
    font-size: 12px;
    color: #fc0;
  }
  .ss-settings-field input[type="text"],
  .ss-settings-field input[type="number"],
  .ss-settings-field select {
    width: 100%;
    max-width: 100%;
    box-sizing: border-box;
  }
  .ss-modal-head {
    font-size: 16px;
    font-weight: 700;
    color: #fc0;
    margin-bottom: 8px;
  }
  .ss-modal-summary {
    color: #cfd8dc;
    font-size: 13px;
    line-height: 1.45;
    margin: 0 0 10px;
  }
  .ss-modal-section { margin: 10px 0 6px; }
  .ss-modal-section h4 {
    margin: 0 0 4px;
    font-size: 13px;
    color: #fc0;
  }
  .ss-modal-section ul {
    margin: 0;
    padding-left: 18px;
    color: #fff;
    font-size: 12px;
    line-height: 1.45;
  }
  .ss-modal-section li { margin: 3px 0; }
  .ss-modal-actions {
    margin-top: 14px;
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    align-items: center;
  }
  .ss-modal-link {
    color: #fc0;
    font-size: 12px;
    margin-left: auto;
  }
  .ss-suggest-wrap { position: relative; display: inline-block; vertical-align: middle; }
  .ss-suggest-box {
    display: none;
    position: absolute;
    z-index: 40;
    left: 0;
    right: 0;
    top: 100%;
    max-height: 180px;
    overflow: auto;
    background: #2f3a3e;
    border: 1px solid #fc0;
    margin-top: 2px;
  }
  .ss-suggest-box.show { display: block; }
  .ss-suggest-item {
    display: block;
    width: 100%;
    text-align: left;
    padding: 5px 8px;
    border: 0;
    background: transparent;
    color: #fff;
    font-size: 12px;
    cursor: pointer;
  }
  .ss-suggest-item:hover,
  .ss-suggest-item.active {
    background: #4d595d;
    color: #fc0;
  }
  .ss-suggest-empty {
    padding: 6px 8px;
    color: #9ab;
    font-size: 11px;
  }
  #ruleMatcher { width: 260px; }
  #conflictBanner {
    display: none;
    margin: 8px 0 12px;
    padding: 10px 12px;
    border: 1px solid #f66;
    background: rgba(255, 68, 68, 0.14);
    color: #ffb3b3;
    font-size: 13px;
    line-height: 1.45;
  }
  #conflictBanner.show { display: block; }
  #conflictBanner b { color: #ff8080; }
  #conflictBanner code {
    background: #2f3a3e;
    padding: 1px 4px;
    border-radius: 2px;
    font-size: 11px;
    color: #fff;
  }
  #btnStart:disabled,
  #btnRestart:disabled {
    opacity: 0.45;
    cursor: not-allowed;
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
  /* Keep Merlin chrome visible; do not collapse menu column if empty before show_menu */
  table.content { width: 100%; }
</style>
</head>
<body onload="initial();" class="bg">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>

<form method="post" name="form" id="ruleForm" action="start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" id="ss_current_page" value="user1.asp">
<input type="hidden" name="next_page" id="ss_next_page" value="user1.asp">
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
    <td valign="top" width="202">
      <div id="mainMenu"></div>
      <div id="subMenu"></div>
    </td>
    <td valign="top">
      <div id="tabMenu" class="submenuBlock"></div>
      <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
        <tr>
          <td align="left" valign="top">
            <table width="760px" border="0" cellpadding="5" cellspacing="0" bordercolor="#6b8fa3" id="FormTitle" class="FormTitle">
              <tr bgcolor="#4D595D">
                <td valign="top">
                  <div>&nbsp;</div>
                  <div class="formfonttitle" style="text-align:left">StealthSurf UI <span id="titleVer"></span></div>
                  <div id="formfontdesc" class="formfontdesc">
                    Управление каталогом конфигов StealthSurf, transparent proxy, routing и политиками устройств на роутере.
                    После изменений на сайте нажмите <b>Синхронизировать</b>.
                  </div>
                  <div style="margin:10px 0 10px 5px;" class="splitLine"></div>

                  <div id="updateBanner">
                    <div>
                      Доступна новая версия: <b id="bannerLatest">—</b>
                      (установлена <span id="bannerInstalled">—</span>)
                    </div>
                    <div class="row-buttons">
                      <input id="btnBannerChangelog" class="button_gen button_gen_small" type="button" value="Что нового">
                      <input id="btnBannerUpdate" class="button_gen button_gen_small" type="button" value="Установить обновление">
                    </div>
                  </div>

                  <div id="updateModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="modalTitle">
                    <div class="ss-modal-card">
                      <div class="ss-modal-head" id="modalTitle">Доступно обновление <span id="modalLatest">—</span></div>
                      <p class="ss-modal-summary" id="modalSummary">Загрузка описания с GitHub…</p>
                      <div class="ss-modal-section" id="modalFeatBox" style="display:none">
                        <h4>Новое</h4>
                        <ul id="modalFeatures"></ul>
                      </div>
                      <div class="ss-modal-section" id="modalFixBox" style="display:none">
                        <h4>Исправления</h4>
                        <ul id="modalFixes"></ul>
                      </div>
                      <div class="ss-modal-section" id="modalOtherBox" style="display:none">
                        <h4>Ещё изменения</h4>
                        <ul id="modalOther"></ul>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnModalUpdate" class="button_gen button_gen_small" type="button" value="Установить с GitHub">
                        <input id="btnModalLater" class="button_gen button_gen_small" type="button" value="Позже">
                        <input id="btnModalClose" class="button_gen button_gen_small" type="button" value="Закрыть">
                        <a id="modalGhLink" class="ss-modal-link" href="#" target="_blank" rel="noopener">Открыть релиз на GitHub</a>
                      </div>
                    </div>
                  </div>

                  <div id="settingsModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="settingsTitle">
                    <div class="ss-modal-card ss-settings-card">
                      <div class="ss-modal-head" id="settingsTitle">Настройки StealthSurf</div>
                      <p class="ss-modal-summary">Автозапуск, плановая перезагрузка, backup и обновление geoip/geosite.</p>
                      <div class="ss-settings-grid">
                        <div class="ss-modal-section">
                          <h4>Запуск</h4>
                          <div class="ss-settings-row">
                            <label class="ss-check"><input id="setAutoStart" type="checkbox"> Автостарт после перезагрузки роутера</label>
                            <label class="ss-check"><input id="setWatchdog" type="checkbox"> Watchdog (авто-рестарт при падении)</label>
                          </div>
                          <div class="ss-settings-row" style="margin-top:6px">
                            <div class="ss-settings-field">
                              <span>Задержка автостарта (сек)</span>
                              <input id="setStartupDelay" class="input_15_table" type="number" min="0" max="120" value="8">
                            </div>
                          </div>
                        </div>
                        <div class="ss-modal-section">
                          <h4>Перезагрузка по плану</h4>
                          <div class="ss-settings-row">
                            <div class="ss-settings-field">
                              <span>Периодичность</span>
                              <select id="setRebootSchedule" class="input_25_table">
                                <option value="off">Выкл</option>
                                <option value="daily">Ежедневно в 04:15</option>
                                <option value="weekly">Еженедельно (вс 04:15)</option>
                                <option value="monthly">Ежемесячно (1-е, 04:15)</option>
                                <option value="custom">Свой cron</option>
                              </select>
                            </div>
                            <div class="ss-settings-field" id="setRebootCronWrap" style="display:none">
                              <span>Cron (min hour dom mon dow)</span>
                              <input id="setRebootCron" class="input_32_table" type="text" placeholder="15 4 * * 0" maxlength="64">
                            </div>
                          </div>
                          <div class="ss-hint">Перезагружает весь роутер (`/sbin/reboot`). Используйте осторожно.</div>
                        </div>
                        <div class="ss-modal-section">
                          <h4>Резервное копирование</h4>
                          <div class="ss-settings-row">
                            <label class="ss-check"><input id="setAutoBackup" type="checkbox"> Ночной backup в 03:00</label>
                            <div class="ss-settings-field" style="flex:0 1 140px">
                              <span>Хранить копий</span>
                              <input id="setBackupKeep" class="input_15_table" type="number" min="1" max="50" value="10">
                            </div>
                          </div>
                          <div class="ss-settings-row" style="margin-top:6px">
                            <input id="setBackupNote" class="input_25_table" type="text" placeholder="заметка (опц.)" maxlength="64">
                            <span class="row-buttons">
                              <input id="btnSettingsBackup" class="button_gen button_gen_small" type="button" value="Создать backup">
                              <input id="btnSettingsBackupList" class="button_gen button_gen_small" type="button" value="Список backup">
                            </span>
                          </div>
                          <div id="settingsBackupHint" class="ss-hint">Файлы: /opt/share/stealthsurf/backups/</div>
                        </div>
                        <div class="ss-modal-section">
                          <h4>GeoIP / GeoSite</h4>
                          <div class="ss-settings-row">
                            <label class="ss-check"><input id="setGeodataAuto" type="checkbox"> Автообновление geoip.dat и geosite.dat</label>
                            <div class="ss-settings-field" style="flex:0 1 180px">
                              <span>Периодичность</span>
                              <select id="setGeodataSchedule" class="input_25_table">
                                <option value="daily">Ежедневно</option>
                                <option value="every3d">Каждые 3 дня</option>
                                <option value="weekly">Еженедельно</option>
                                <option value="monthly">Ежемесячно</option>
                              </select>
                            </div>
                          </div>
                          <div class="ss-settings-row" style="margin-top:6px">
                            <div class="ss-settings-field" style="flex:1 1 100%">
                              <span>Адрес загрузки (без имени файла)</span>
                              <input id="setGeodataBase" class="input_32_table" type="text" maxlength="256"
                                placeholder="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download">
                            </div>
                          </div>
                          <div class="ss-hint">Скачиваются <code>geoip.dat</code> и <code>geosite.dat</code> с указанного URL.</div>
                          <div class="ss-settings-row" style="margin-top:6px">
                            <input id="btnSettingsGeodataNow" class="button_gen button_gen_small" type="button" value="Обновить geoip/geosite сейчас">
                          </div>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnSettingsSave" class="button_gen button_gen_small" type="button" value="Сохранить">
                        <input id="btnSettingsClose" class="button_gen button_gen_small" type="button" value="Закрыть">
                        <span id="settingsStatus" class="ss-hint" style="margin-left:auto"></span>
                      </div>
                    </div>
                  </div>

                  <div id="conflictBanner">
                    <b>Конфликт с XrayUI</b> — <span id="conflictText">XrayUI сейчас работает. Запуск StealthSurf заблокирован.</span>
                    <div style="margin-top:6px">
                      Остановите XrayUI (VPN → XrayUI → Stop), затем нажмите <b>Старт</b> здесь.
                      Одновременно оба transparent-proxy аддона использовать нельзя — пропадёт интернет в LAN.
                    </div>
                  </div>

                  <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable" id="sec-config">
                    <thead>
                      <tr>
                        <td colspan="2">
                          Configuration
                          <span class="ss-core-ver" id="installedVer">—</span>
                        </td>
                      </tr>
                    </thead>
                    <tbody>
                      <tr>
                        <th width="30%">Connection status</th>
                        <td>
                          <span id="runState" class="label label-error">stopped</span>
                          <span id="conflictPill" class="label label-error" style="display:none">XrayUI конфликт</span>
                          <span id="xrayuiPill" class="label label-warning" style="display:none">XrayUI установлен</span>
                          <span class="row-buttons">
                            <input id="btnStart" class="button_gen button_gen_small" type="button" value="start">
                            <input id="btnRestart" class="button_gen button_gen_small" type="button" value="restart" style="display:none">
                            <input id="btnStop" class="button_gen button_gen_small" type="button" value="stop" style="display:none">
                            <input id="btnRefresh" class="button_gen button_gen_small" type="button" value="refresh">
                          </span>
                          <div class="ss-meta-inline" style="clear:both;margin-top:6px">
                            <span id="activeCfg">active: —</span>
                            · <span id="modePill">mode: —</span>
                            · <span id="ports">ports: —</span>
                            · <span id="defaultPill">default: —</span>
                            · <span id="latestVer">GitHub: —</span>
                            <span id="updatePill" class="label label-warning" style="display:none">update</span>
                          </div>
                        </td>
                      </tr>
                      <tr>
                        <th>Sync с сайта</th>
                        <td>
                          <span class="ss-meta-inline">Подтянуть конфиги / ключи с api.stealthsurf.net</span>
                          <span class="row-buttons">
                            <input id="btnSync" class="button_gen button_gen_small" type="button" value="sync">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th>General options</th>
                        <td>
                          <span class="ss-meta-inline">Автостарт, reboot по плану, backup, geoip/geosite</span>
                          <span class="row-buttons">
                            <input id="btnSettings" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th>Update</th>
                        <td>
                          <span class="ss-meta-inline" id="verDetail">—</span>
                          <span class="row-buttons">
                            <input id="btnCheckUpdate" class="button_gen button_gen_small" type="button" value="check">
                            <input id="btnUpdate" class="button_gen button_gen_small" type="button" value="install" style="display:none">
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>

                  <!-- Keys -->
                  <div class="ss-panel" id="tab-keys">
                    <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">API keys</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Добавить ключ</th>
                          <td>
                            <input id="apiKey" class="input_32_table" type="password" maxlength="128" placeholder="stlth_........_........................" autocomplete="off">
                            <input id="apiKeyLabel" class="input_15_table" type="text" maxlength="64" placeholder="метка (опц.)" style="margin-left:6px">
                            <span class="row-buttons" style="margin-left:6px">
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
                  <div class="ss-panel" id="tab-catalog" data-sec="catalog">
                    <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Outbounds / catalog</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Фильтр / default</th>
                          <td>
                            <input id="catalogFilter" class="input_25_table" type="text" placeholder="название / протокол / id">
                            <select id="defaultOutbound" class="input_15_table" style="margin-left:6px"></select>
                            <span class="row-buttons" style="margin-left:6px">
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
                            <div class="row-buttons" style="margin-top:8px">
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
                  <div class="ss-panel" id="tab-routing" data-sec="routing">
                    <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Routing</td></tr></thead>
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
                          <th>Новое правило</th>
                          <td>
                            <div style="margin-bottom:6px">
                              <select id="ruleType" class="input_15_table" title="тип matcher">
                                <option value="domain">domain (поддомены)</option>
                                <option value="full">full (точный хост)</option>
                                <option value="keyword">keyword</option>
                                <option value="geosite">geosite ( Loyalsoldier )</option>
                                <option value="geoip">geoip</option>
                                <option value="ip">ip / cidr</option>
                                <option value="regexp">regexp</option>
                              </select>
                              <select id="ruleOutbound" class="input_25_table" style="margin-left:6px" title="куда слать"></select>
                            </div>
                            <div style="margin-bottom:6px">
                              <span class="ss-suggest-wrap">
                                <input id="ruleMatcher" class="input_32_table" type="text" autocomplete="off" placeholder="домен или geosite/geoip…" spellcheck="false">
                                <div id="ruleSuggestBox" class="ss-suggest-box" role="listbox"></div>
                              </span>
                              <input id="ruleName" class="input_15_table" type="text" placeholder="имя (опц.)" style="margin-left:6px" maxlength="40">
                              <input id="rulePriority" class="input_15_table" type="number" placeholder="prio" style="width:70px;margin-left:6px" min="1" max="9999">
                            </div>
                            <div id="ruleSuggestHint" class="ss-hint">
                              Начните вводить домен — подсказки из списка популярных сайтов. Для geosite/geoip — категории из репозитория geodata.
                            </div>
                            <div class="row-buttons" style="margin-top:6px">
                              <input id="btnAddRule" class="button_gen button_gen_small" type="button" value="Добавить в список">
                              <input id="btnSaveRouting" class="button_gen button_gen_small" type="button" value="Сохранить routing + Apply">
                              <input id="btnGeodata" class="button_gen button_gen_small" type="button" value="Обновить geoip/geosite">
                            </div>
                          </td>
                        </tr>
                        <tr>
                          <th>Текущие правила</th>
                          <td>
                            <table class="ss-data-table">
                              <thead>
                                <tr>
                                  <th>#</th><th>Имя</th><th>Тип</th><th>Matcher</th><th>Outbound</th><th>Prio</th><th></th>
                                </tr>
                              </thead>
                              <tbody id="rulesTable"></tbody>
                            </table>
                            <div class="ss-hint" style="margin-top:6px">
                              Outbound <code>ss-&lt;id&gt;</code> — VPN из API-ключа (включите конфиг на вкладке «Мои подключения»).
                              Geosite/geoip берутся из файлов после «Обновить geoip/geosite».
                            </div>
                          </td>
                        </tr>
                        <tr>
                          <th>JSON (дополнительно)</th>
                          <td>
                            <textarea id="routingJson" spellcheck="false"></textarea>
                            <div class="ss-hint">
                              Редактируйте вручную при необходимости. Типы:
                              <code>domain</code>, <code>full</code>, <code>keyword</code>, <code>regexp</code>,
                              <code>geosite</code>, <code>geoip</code>, <code>ip</code>, <code>cidr</code>.
                            </div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                  <!-- Policies -->
                  <div class="ss-panel" id="tab-policies" data-sec="policies">
                    <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Clients / MAC policies</td></tr></thead>
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
                            <span class="row-buttons" style="margin-left:6px">
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
                  <div class="ss-panel" id="tab-general" data-sec="general">
                    <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Mode / DNS</td></tr></thead>
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
                            <span class="row-buttons" style="margin-left:6px">
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
                  <div class="ss-panel" id="tab-backup" data-sec="backup">
                    <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Backup / Logs</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Создать</th>
                          <td>
                            <div class="ss-hint">
                              В архив: conf, routing, outbounds, policies, configs/keys, xray.json.
                              Ночной backup в 03:00. Файлы: <code>/opt/share/stealthsurf/backups/</code>
                            </div>
                            <input id="backupNote" class="input_25_table" type="text" placeholder="заметка (опц.)">
                            <span class="row-buttons" style="margin-left:6px">
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
                            <span class="row-buttons" style="margin-left:6px">
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
                  <div class="ss-panel" id="tab-diag" data-sec="diag">
                    <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Diagnostics</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Действия</th>
                          <td>
                            <span class="row-buttons">
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

                  <div class="apply_gen">
                    <input id="btnApplyAll" class="button_gen" type="button" value="Apply">
                  </div>
                  <div class="ss-version">
                    <a href="#" id="btnVersionFooter" title="Проверить обновление">STEALTHSURF <span id="footerVer">v—</span></a>
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
<script type="text/javascript" src="/ext/stealthsurf/routing-suggest.js"></script>
<script type="text/javascript" src="/ext/stealthsurf/app.js"></script>
</body>
</html>
