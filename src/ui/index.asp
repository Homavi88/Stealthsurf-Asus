<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
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
  try {
    if (typeof show_menu === "function") show_menu();
  } catch (e) {
    if (typeof console !== "undefined" && console.warn) console.warn("StealthSurf show_menu:", e);
  }
}
</script>
<style type="text/css">
  /* Layout/buttons aligned with XrayUI (Asuswrt-Merlin FormTable patterns) */
  /* overDiv must sit above .ss-modal (10050) or Merlin overlib tips vanish inside Manage windows */
  #overDiv { z-index: 11050; }
  #Loading { z-index: 12000; }
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
  .apply_gen .button_gen:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
  .ss-pending {
    margin: 8px auto 0;
    max-width: 520px;
    text-align: left;
    font-size: 12px;
    color: #cfd8dc;
  }
  .ss-pending-title {
    font-weight: bold;
    color: #fc0;
    margin-bottom: 4px;
    text-align: center;
  }
  .ss-pending-list {
    margin: 0;
    padding: 6px 10px;
    background: rgba(0, 0, 0, 0.18);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 4px;
  }
  .ss-pending-list ul {
    margin: 0;
    padding-left: 18px;
  }
  .ss-pending-list li {
    margin: 2px 0;
  }
  .ss-pending-list.empty,
  .ss-pending-empty {
    text-align: center;
    color: #90a4ae;
    font-style: italic;
    padding: 4px 0;
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
  .ss-modal-card.ss-versions-card {
    width: min(620px, 96vw);
  }
  .ss-version-select-row {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
    margin: 0 0 10px;
  }
  .ss-version-select-row select {
    flex: 1 1 220px;
    min-width: 180px;
    max-width: 100%;
  }
  .ss-version-badge {
    display: inline-block;
    padding: 2px 8px;
    font-size: 11px;
    border: 1px solid #6b8fa3;
    color: #cfd8dc;
  }
  .ss-version-badge.newer { border-color: #8bc34a; color: #8bc34a; }
  .ss-version-badge.older { border-color: #ff9800; color: #ff9800; }
  .ss-version-badge.same { border-color: #fc0; color: #fc0; }
  .ss-versions-status {
    display: none;
    margin: 0 0 10px;
    padding: 8px 10px;
    font-size: 12px;
    border: 1px solid #6b8fa3;
    background: rgba(0, 0, 0, 0.18);
    color: #cfd8dc;
  }
  .ss-versions-status.loading { border-color: #fc0; color: #fc0; }
  .ss-versions-status.warn { border-color: #ff9800; color: #ff9800; }
  .ss-versions-status.error { border-color: #f44336; color: #ff8a80; }
  .ss-version-status-row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 10px 14px;
    margin: 0 0 12px;
    padding: 10px 12px;
    background: linear-gradient(180deg, rgba(0, 0, 0, 0.18), rgba(0, 0, 0, 0.05));
    border: 1px solid #222;
    border-left: 3px solid #6b7a7f;
  }
  .ss-version-pill {
    display: inline-block;
    padding: 3px 10px;
    background: #2f3a3e;
    border: 1px solid #222;
    font-family: "Courier New", Courier, monospace;
    font-weight: bold;
    font-size: 12px;
    color: #fff;
  }
  .ss-version-pill.latest { border-color: #fc0; color: #fc0; }
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
  /* Do NOT override .content width — Merlin uses 998px + middown_bg (same as XrayUI). */

  /* Merlin-like hintstyle: hover label → tip (overlib / fallback), no click */
  .ss-hintstyle {
    cursor: help !important;
    border-bottom: 1px dashed #fc0;
  }
  th.ss-hintstyle,
  h4.ss-hintstyle,
  thead td.ss-hintstyle {
    border-bottom-color: transparent;
  }
  th.ss-hintstyle {
    text-decoration: underline;
    text-decoration-style: dashed;
    text-decoration-color: #fc0;
    text-underline-offset: 2px;
  }
  label.ss-hintstyle,
  span.ss-hintstyle {
    border-bottom: 1px dashed #fc0;
  }
  #ssHelpTip {
    display: none;
    position: fixed;
    z-index: 11060;
    max-width: min(380px, 92vw);
    padding: 10px 12px;
    background: #2f3a3e;
    border: 1px solid #fc0;
    color: #fff;
    font-size: 12px;
    line-height: 1.45;
    box-shadow: 0 8px 24px rgba(0,0,0,0.45);
    pointer-events: none;
  }
  #ssHelpTip.show { display: block; }

  .ss-proxy-tag {
    display: inline-block;
    color: #fff;
    padding: 2px 6px;
    border-radius: 4px;
    margin: 2px 4px 2px 0;
    font-size: 11px;
    font-weight: bold;
    border: 1px solid #fc0;
    background: transparent;
  }
  .ss-proxy-tag.proto { border-color: #fc0; color: #fc0; }
  .ss-proxy-tag.runtime { border-color: #8bc34a; color: #8bc34a; background: rgba(139,195,74,0.12); }
  .ss-proxy-tag.sec { border-color: #b388ff; color: #b388ff; }
  .ss-proxy-tag.off { border-color: #6b757b; color: #9ab; }
  .ss-proxy-dot {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    margin-right: 6px;
    vertical-align: middle;
    background: #6b757b;
  }
  .ss-proxy-dot.on { background: #4caf50; box-shadow: 0 0 4px #4caf50; }
  .ss-proxy-dot.err { background: #f44336; box-shadow: 0 0 4px #f44336; }
  .ss-proxy-row th {
    white-space: nowrap;
    max-width: 180px;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .ss-modal-card.ss-wide-card {
    width: min(980px, 98vw);
  }
  .ss-modal-card .FormTable {
    margin-bottom: 8px;
    table-layout: auto;
    width: 100%;
  }
  .ss-modal-card .FormTable thead { display: none; }
  /* Shrink label column to text; give content column the rest (XrayUI modal feel) */
  .ss-modal-card .FormTable th,
  .ss-modal-card .FormTable th[width],
  .ss-modal-card .FormTable th[width="30%"] {
    width: 1% !important;
    max-width: 160px;
    white-space: nowrap;
    vertical-align: top;
    padding-right: 10px;
  }
  .ss-modal-card .FormTable td {
    width: auto;
    vertical-align: top;
  }
  .ss-modal-card .FormTable input.input_25_table,
  .ss-modal-card .FormTable input.input_32_table,
  .ss-modal-card .FormTable select.input_25_table,
  .ss-modal-card .FormTable select.input_32_table {
    max-width: 100%;
    box-sizing: border-box;
  }
  .ss-modal-card .ss-table-scroll {
    width: 100%;
  }
  .ss-modal-card .ss-data-table {
    min-width: 100%;
  }
  .ss-section-menu th { width: 30%; }
  .ss-table-scroll {
    width: 100%;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }
  .ss-table-scroll .ss-data-table {
    min-width: 520px;
  }
  .ss-data-table .ss-col-hide-sm { }
  .ss-menu-summary {
    color: #cfd8dc;
    font-size: 12px;
    margin-right: 8px;
  }
  .ss-modal-body {
    max-height: calc(86vh - 70px);
    overflow: auto;
  }
  @media (max-width: 860px) {
    /* Keep Merlin .content at 998px (middown_bg). Only shrink FormTitle inside. */
    #FormTitle { width: 100% !important; max-width: 760px; }
    .FormTable input.input_25_table,
    .FormTable input.input_32_table,
    .FormTable input.input_15_table,
    .FormTable select.input_25_table,
    .FormTable select.input_32_table,
    .FormTable select.input_15_table,
    #ruleMatcher {
      width: 100% !important;
      max-width: 100%;
      box-sizing: border-box;
    }
    .row-buttons, .ss-row-buttons {
      float: none;
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
      margin-top: 6px;
    }
    .ss-data-table .ss-col-hide-sm { display: none; }
    .ss-table-scroll .ss-data-table { min-width: 420px; }
    .ss-opt-row label {
      display: block;
      margin: 4px 0;
    }
    .ss-modal {
      padding: 8px;
      align-items: flex-start;
    }
    .ss-modal-card,
    .ss-modal-card.ss-settings-card,
    .ss-modal-card.ss-versions-card,
    .ss-modal-card.ss-wide-card {
      width: 100%;
      max-height: 94vh;
      margin-top: 2vh;
    }
    .ss-core-ver { float: none; display: block; margin-top: 4px; }
  }
</style>
</head>
<body onload="initial();" class="bg">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>

<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
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
  <tbody>
  <tr>
    <td width="17">&nbsp;</td>
    <td valign="top" width="202">
      <div id="mainMenu"></div>
      <div id="subMenu"></div>
    </td>
    <td valign="top">
      <div id="tabMenu" class="submenuBlock"></div>
      <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
        <tbody>
        <tr>
          <td valign="top">
            <table width="760px" border="0" cellpadding="4" cellspacing="0" id="FormTitle" class="FormTitle">
              <tbody>
              <tr bgcolor="#4D595D">
                <td valign="top">
                  <div class="formfontdesc">
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
                      <div class="ss-modal-head" id="modalTitle">Доступна новая версия <span id="modalLatest">—</span></div>
                      <p class="ss-modal-summary" id="modalSummary">На GitHub вышла более новая версия аддона StealthSurf.</p>
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
                        <input id="btnModalUpdate" class="button_gen button_gen_small" type="button" value="Обновить">
                        <input id="btnModalLater" class="button_gen button_gen_small" type="button" value="Обновить позднее">
                        <input id="btnModalClose" class="button_gen button_gen_small" type="button" value="Закрыть уведомление">
                        <a id="modalGhLink" class="ss-modal-link" href="#" target="_blank" rel="noopener">Открыть релиз на GitHub</a>
                      </div>
                    </div>
                  </div>

                  <div id="versionsModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="versionsTitle">
                    <div class="ss-modal-card ss-versions-card">
                      <div class="ss-modal-head" id="versionsTitle">Версии аддона</div>
                      <div class="ss-version-status-row">
                        <span class="ss-version-pill" id="versionsInstalled">—</span>
                        <span class="ss-meta-inline">Список с GitHub · без Apply / %</span>
                      </div>
                      <p class="ss-modal-summary">
                        Выберите свежую или более старую версию. Список загружается прямо из GitHub API
                        (как в XrayUI) — без экрана «применение настроек».
                      </p>
                      <div id="versionsStatus" class="ss-versions-status" role="status" aria-live="polite"></div>
                      <div class="ss-version-select-row">
                        <select id="versionSelect" class="input_25_table">
                          <option value="">Загрузка списка с GitHub…</option>
                        </select>
                        <span id="versionDirection" class="ss-version-badge">—</span>
                      </div>
                      <p class="ss-modal-summary" id="versionPickSummary">Выберите версию в списке.</p>
                      <div class="ss-modal-section" id="verFeatBox" style="display:none">
                        <h4>Новое</h4>
                        <ul id="verFeatures"></ul>
                      </div>
                      <div class="ss-modal-section" id="verFixBox" style="display:none">
                        <h4>Исправления</h4>
                        <ul id="verFixes"></ul>
                      </div>
                      <div class="ss-modal-section" id="verOtherBox" style="display:none">
                        <h4>Ещё изменения</h4>
                        <ul id="verOther"></ul>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnVersionInstall" class="button_gen button_gen_small" type="button" value="Установить выбранную" disabled>
                        <input id="btnVersionsRefresh" class="button_gen button_gen_small" type="button" value="Обновить список">
                        <input id="btnVersionsClose" class="button_gen button_gen_small" type="button" value="Закрыть">
                        <a id="versionGhLink" class="ss-modal-link" href="#" target="_blank" rel="noopener" style="display:none">Релиз на GitHub</a>
                      </div>
                    </div>
                  </div>

                  <div id="settingsModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="settingsTitle">
                    <div class="ss-modal-card ss-settings-card">
                      <div class="ss-modal-head" id="settingsTitle">Настройки StealthSurf</div>
                      <p class="ss-modal-summary">Автозапуск, плановая перезагрузка, backup и обновление geoip/geosite.</p>
                      <div class="ss-settings-grid">
                        <div class="ss-modal-section">
                          <h4 data-ss-hint="Когда и как StealthSurf стартует на роутере после включения электричества или перезагрузки.">Запуск</h4>
                          <div class="ss-settings-row">
                            <label class="ss-check" data-ss-hint="Если включено, StealthSurf сам запустится после перезагрузки роутера — вам не нужно заходить в веб-интерфейс и нажимать Start."><input id="setAutoStart" type="checkbox"> Автостарт после перезагрузки роутера</label>
                            <label class="ss-check" data-ss-hint="Сторож: если защита внезапно остановилась, роутер сам попробует запустить её снова."><input id="setWatchdog" type="checkbox"> Watchdog (авто-рестарт при падении)</label>
                          </div>
                          <div class="ss-settings-row" style="margin-top:6px">
                            <div class="ss-settings-field">
                              <span data-ss-hint="Пауза после включения роутера, прежде чем запускать StealthSurf. Нужна, чтобы интернет и USB/Entware успели подняться. Обычно 5–15 секунд.">Задержка автостарта (сек)</span>
                              <input id="setStartupDelay" class="input_15_table" type="number" min="0" max="120" value="8">
                            </div>
                          </div>
                        </div>
                        <div class="ss-modal-section">
                          <h4 data-ss-hint="Автоматическая полная перезагрузка роутера по расписанию. Нужна редко; если всё стабильно — лучше выключить.">Перезагрузка по плану</h4>
                          <div class="ss-settings-row">
                            <div class="ss-settings-field">
                              <span data-ss-hint="Как часто перезагружать весь роутер по расписанию. Это полная перезагрузка устройства, не только VPN. Если не нужно — оставьте «Выкл».">Периодичность</span>
                              <select id="setRebootSchedule" class="input_25_table">
                                <option value="off">Выкл</option>
                                <option value="daily">Ежедневно в 04:15</option>
                                <option value="weekly">Еженедельно (вс 04:15)</option>
                                <option value="monthly">Ежемесячно (1-е, 04:15)</option>
                                <option value="custom">Свой cron</option>
                              </select>
                            </div>
                            <div class="ss-settings-field" id="setRebootCronWrap" style="display:none">
                              <span data-ss-hint="Свой график в формате cron (для тех, кто знаком). Пять полей: минута час день месяц день_недели. Пример: 15 4 * * 0 — каждое воскресенье в 04:15.">Cron (min hour dom mon dow)</span>
                              <input id="setRebootCron" class="input_32_table" type="text" placeholder="15 4 * * 0" maxlength="64">
                            </div>
                          </div>
                          <div class="ss-hint">Перезагружает весь роутер (`/sbin/reboot`). Используйте осторожно.</div>
                        </div>
                        <div class="ss-modal-section">
                          <h4 data-ss-hint="Запасные копии настроек, чтобы можно было откатиться, если что-то сломалось.">Резервное копирование</h4>
                          <div class="ss-settings-row">
                            <label class="ss-check" data-ss-hint="Каждую ночь в 3:00 роутер сохранит копию настроек StealthSurf. Удобно откатиться, если что-то сломается."><input id="setAutoBackup" type="checkbox"> Ночной backup в 03:00</label>
                            <div class="ss-settings-field" style="flex:0 1 140px">
                              <span data-ss-hint="Сколько последних ночных копий оставлять. Старые удаляются автоматически, чтобы не забивать память.">Хранить копий</span>
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
                          <h4 data-ss-hint="Справочники «какой IP/сайт к какой стране относится». Используются правилами маршрутизации.">GeoIP / GeoSite</h4>
                          <div class="ss-settings-row">
                            <label class="ss-check" data-ss-hint="Сами обновлять списки «какие сайты и IP относятся к странам». Нужны для правил вроде «Россия напрямую». Без свежих файлов часть правил может устареть."><input id="setGeodataAuto" type="checkbox"> Автообновление geoip.dat и geosite.dat</label>
                            <div class="ss-settings-field" style="flex:0 1 180px">
                              <span data-ss-hint="Как часто скачивать свежие списки стран и сайтов. Обычно достаточно раз в неделю.">Периодичность</span>
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
                              <span data-ss-hint="Готовые наборы geodata как в XrayUI. Выбор подставляет URL для geoip.dat и geosite.dat. Для своего зеркала выберите «Свой URL».">Репозиторий geodata</span>
                              <select id="setGeodataPreset" class="input_32_table">
                                <option value="loyalsoldier">Loyalsoldier (общий, по умолчанию)</option>
                                <option value="runetfreedom">RUNET Freedom (RU bypass)</option>
                                <option value="nidelon">Nidelon (RU blocks)</option>
                                <option value="dustinwin">DustinWin (CN rules)</option>
                                <option value="chocolate4u">Chocolate4U (Iran rules)</option>
                                <option value="custom">Свой URL…</option>
                              </select>
                            </div>
                          </div>
                          <div class="ss-settings-row" style="margin-top:6px">
                            <div class="ss-settings-field" style="flex:1 1 100%">
                              <span data-ss-hint="Базовый URL без имени файла. С него скачиваются geoip.dat и geosite.dat. При выборе пресета заполняется автоматически.">Адрес загрузки (без имени файла)</span>
                              <input id="setGeodataBase" class="input_32_table" type="text" maxlength="256"
                                placeholder="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download">
                            </div>
                          </div>
                          <div class="ss-hint">Источники как в <a href="https://daniellavrushin.github.io/asuswrt-merlin-xrayui/en/general-options" target="_blank" rel="noopener">XrayUI Geodata</a>. Скачиваются <code>geoip.dat</code> и <code>geosite.dat</code>.</div>
                          <div class="ss-settings-row" style="margin-top:6px">
                            <input id="btnSettingsGeodataNow" class="button_gen button_gen_small" type="button" value="Обновить geoip/geosite сейчас">
                          </div>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnSettingsSave" class="button_gen button_gen_small" type="button" value="В очередь">
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
                        <th width="30%" data-ss-hint="Показывает, работает ли защита прямо сейчас. Start — включить, Stop — выключить, Restart — перезапустить. Refresh просто обновляет картинку на экране, ничего не меняя.">Connection status</th>
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
                        <th data-ss-hint="Скачивает с сайта StealthSurf ваши актуальные серверы и настройки по API-ключу. Нажимайте после изменений в личном кабинете на сайте.">Sync с сайта</th>
                        <td>
                          <span class="ss-meta-inline" id="lastSyncLabel">Последняя синхронизация: ещё не было</span>
                          <span class="row-buttons">
                            <input id="btnSync" class="button_gen button_gen_small" type="button" value="sync">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Это «пароль» от вашего аккаунта StealthSurf. Без ключа роутер не сможет скачать ваши серверы. Manage открывает окно, где ключ можно добавить или удалить. Рядом показывается баланс счёта с api.stealthsurf.net (обновляется при открытии окна ключей или кнопкой «Обновить баланс»).">API keys</th>
                        <td>
                          <span class="ss-menu-summary" id="sumKeys">ключей: —</span>
                          <span class="ss-meta-inline" id="sumBalance" style="margin-left:8px">баланс: —</span>
                          <span class="row-buttons">
                            <input id="btnManageKeys" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Базовые удобства: автозапуск после перезагрузки роутера, плановая перезагрузка, ночные копии настроек и обновление списков стран/сайтов для маршрутизации.">General options</th>
                        <td>
                          <span class="ss-meta-inline">Автостарт, reboot по плану, geoip/geosite</span>
                          <span class="row-buttons">
                            <input id="btnSettings" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Запасная копия настроек «на всякий случай». Manage открывает список копий и восстановление.">Backup</th>
                        <td>
                          <span class="ss-menu-summary" id="sumBackup">резервные копии настроек</span>
                          <span class="row-buttons">
                            <input id="btnManageBackup" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Журнал работы аддона: действия, ошибки, устройства, логи Xray. Отдельный раздел — сюда пишется всё по программе.">Logs</th>
                        <td>
                          <span class="ss-menu-summary" id="sumLogs">activity / errors / xray</span>
                          <span class="row-buttons">
                            <input id="btnManageLogs" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Проверка новой версии аддона на GitHub. Check — посмотреть, есть ли обновление. Versions / rollback — поставить другую версию или откатиться назад.">Update</th>
                        <td>
                          <span class="ss-meta-inline" id="verDetail">—</span>
                          <span class="row-buttons">
                            <input id="btnCheckUpdate" class="button_gen button_gen_small" type="button" value="check">
                            <input id="btnUpdate" class="button_gen button_gen_small" type="button" value="install" style="display:none">
                            <input id="btnVersions" class="button_gen button_gen_small" type="button" value="versions / rollback">
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>

                  <!-- Outbounds: catalog from StealthSurf API keys; + enables as Xray outbound -->
                  <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable" id="sec-outbounds">
                    <thead>
                      <tr><td colspan="2" data-ss-hint="Каталог конфигов, загруженных по API-ключам. Точка — online у провайдера. «+» — использовать как outbound на роутере, «x» — выключить, «e» — сменить локацию/протокол.">Outbounds / catalog <span class="ss-menu-summary" id="sumCatalog" style="float:right;font-weight:normal"></span></td></tr>
                    </thead>
                    <tbody id="outboundListBody">
                      <tr>
                        <th width="30%" data-ss-hint="Как пользоваться каталогом">Как пользоваться</th>
                        <td>
                          <div class="ss-hint" style="margin:0">
                            Это конфиги с сайта StealthSurf (после Sync по API-ключам).<br>
                            <b>●</b> зелёная — сервер online сейчас; без точки / красная — offline.<br>
                            <b>+</b> — включить как <b>outbound</b> (туннель на роутере, можно несколько).<br>
                            <b>x</b> — выключить outbound · <b>e</b> — настройки локации/протокола.<br>
                            <b>Default</b> — куда идёт трафик без отдельного routing-правила.
                          </div>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Поиск по списку серверов. Default — сервер «по умолчанию». «Пересобрать Xray» заново собирает рабочую конфигурацию на роутере.">Фильтр / default</th>
                        <td>
                          <input id="catalogFilter" class="input_25_table" type="text" placeholder="название / протокол / id">
                          <select id="defaultOutbound" class="input_15_table" style="margin-left:6px"></select>
                          <span class="row-buttons" style="margin-left:6px">
                            <input id="btnSetDefault" class="button_gen button_gen_small" type="button" value="Назначить default">
                            <input id="btnRebuild" class="button_gen button_gen_small" type="button" value="Пересобрать Xray">
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>

                  <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable" id="sec-routing">
                    <thead>
                      <tr><td colspan="2">Routing</td></tr>
                    </thead>
                    <tbody>
                      <tr>
                        <th width="30%" data-ss-hint="Правила решают, какой сайт или приложение идёт через VPN, а какой — напрямую. Manage открывает редактор: готовые пресеты и свои правила.">Правила</th>
                        <td>
                          <span class="ss-menu-summary" id="sumRouting">правил: —</span>
                          <span class="row-buttons">
                            <input id="btnManageRouting" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>

                  <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable ss-section-menu" id="sec-menu">
                    <thead>
                      <tr><td colspan="2">Advanced</td></tr>
                    </thead>
                    <tbody>
                      <tr>
                        <th data-ss-hint="Исключения для отдельных устройств дома (по Wi‑Fi/кабелю). Например, телевизор — мимо VPN, телефон — через VPN. Без правил весь дом идёт в VPN.">Clients / MAC policies</th>
                        <td>
                          <span class="ss-menu-summary" id="sumPolicies">политик: —</span>
                          <span class="row-buttons">
                            <input id="btnManagePolicies" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Как роутер «перехватывает» интернет устройств и как обрабатывает адреса сайтов (DNS). Обычно хватает режима redirect. Меняйте, только если понимаете задачу или по инструкции поддержки.">Mode / DNS</th>
                        <td>
                          <span class="ss-menu-summary" id="sumGeneral">mode: —</span>
                          <span class="row-buttons">
                            <input id="btnManageGeneral" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Ядро Xray — программа, которая реально гоняет VPN-трафик. Здесь видно установленную версию, репозиторий релизов и можно скачать/обновить бинарь под архитектуру роутера.">Xray core</th>
                        <td>
                          <span class="ss-menu-summary" id="sumXray">ядро: —</span>
                          <span class="row-buttons">
                            <input id="btnManageXray" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                      <tr>
                        <th data-ss-hint="Проверочные кнопки: снять снимок состояния, проверить конфиг, узнать ваш IP через VPN и напрямую. Полезно, если «интернет пропал» или что-то не подключается.">Diagnostics</th>
                        <td>
                          <span class="ss-menu-summary" id="sumDiag">тест xray / IP / dump</span>
                          <span class="row-buttons">
                            <input id="btnManageDiag" class="button_gen button_gen_small" type="button" value="manage">
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>

                  <div id="keysModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="keysModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="keysModalTitle">API keys</div>
                      <p class="ss-modal-summary">Добавление и проверка ключей StealthSurf. Несколько ключей собираются в один каталог при sync. Баланс счёта подтягивается с api.stealthsurf.net по каждому ключу.</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-keys">
<table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">API keys</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%" data-ss-hint="Вставьте ключ из личного кабинета StealthSurf (обычно начинается с stlth_). Метка — просто понятное имя, например «основной». «Сохранить и проверить» проверяет ключ на сервере.">Добавить ключ</th>
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
                          <th data-ss-hint="Баланс основного счёта и реферального баланса по каждому сохранённому API-ключу (StealthSurf GET /profile). Кэш на роутере ~2 минуты; кнопка обновляет принудительно.">Баланс счёта</th>
                          <td>
                            <div id="balanceSummary" class="ss-meta-inline">баланс: —</div>
                            <div id="balanceStatus" class="ss-hint" style="margin-top:4px">Ещё не запрашивался</div>
                            <span class="row-buttons" style="margin-top:6px;display:inline-block">
                              <input id="btnRefreshBalance" class="button_gen button_gen_small" type="button" value="Обновить баланс">
                            </span>
                            <div class="ss-table-scroll" style="margin-top:8px"><table class="ss-data-table">
                              <thead><tr><th>Метка</th><th>Ключ</th><th>Баланс</th><th>Реф.</th><th>Статус</th></tr></thead>
                              <tbody id="balanceTable"></tbody>
                            </table></div>
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Список уже сохранённых ключей. Можно держать несколько (например, семейный и рабочий) — при sync серверы соберутся вместе. Удалить — убрать ключ с роутера.">Сохранённые ключи</th>
                          <td>
                            <div class="ss-table-scroll"><table class="ss-data-table">
                              <thead><tr><th>Метка</th><th>Ключ (хвост)</th><th></th></tr></thead>
                              <tbody id="keysTable"></tbody>
                            </table></div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_keysModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
                                    <div
                                    id="catalogModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="catalogModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="catalogModalTitle">Outbound settings</div>
                      <p class="ss-modal-summary" id="catalogModalSummary">Смена location / protocol и опции для выбранного конфига.</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-catalog">
                          <table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                            <tbody>
                              <tr>
                                <th width="30%" data-ss-hint="Какой сервер из каталога сейчас редактируете. Выберите нужный из списка.">Конфиг</th>
                                <td>
                                  <select id="configSelect" class="input_32_table"></select>
                                </td>
                              </tr>
                              <tr>
                                <th data-ss-hint="Страна/город сервера и тип подключения (протокол). Галочки ниже — дополнительные режимы (быстрее/обход блокировок). После смены на сайте нажмите «Синхронизировать» на главной.">Location / protocol</th>
                                <td>
                                  <select id="locationSelect" class="input_25_table"></select>
                                  <select id="protocolSelect" class="input_25_table" style="margin-left:6px"></select>
                                  <div class="ss-opt-row" style="margin-top:8px">
                                    <label data-ss-hint="Дополнительный способ передачи данных (XHTTP). Иногда помогает, когда обычный режим режут. Включайте, если так рекомендует сайт или поддержка."><input type="checkbox" id="optUseXhttp"> use_xhttp</label>
                                    <label data-ss-hint="Транспорт gRPC. Нужен только если ваш сервер/тариф его использует — иначе можно не трогать."><input type="checkbox" id="optUseGrpc"> use_grpc</label>
                                    <label data-ss-hint="Часть трафика через Cloudflare WARP. Может помочь с доступом к некоторым сайтам, но усложняет схему."><input type="checkbox" id="optUseWarp"> use_warp</label>
                                    <label data-ss-hint="Доп. маскировка для Hysteria. Имеет смысл только для таких серверов; иначе не включайте."><input type="checkbox" id="optUseSalamander"> use_salamander</label>
                                    <label data-ss-hint="Отключить Reality (маскировку под обычный HTTPS). Обычно лучше оставить Reality включённым. Отключайте только по инструкции."><input type="checkbox" id="optDisableReality"> disable_reality</label>
                                  </div>
                                  <div class="row-buttons" style="margin-top:8px">
                                    <input id="btnUpdateSettings" class="button_gen button_gen_small" type="button" value="PATCH на StealthSurf">
                                    <input id="btnApplySole" class="button_gen button_gen_small" type="button" value="Apply как единственный">
                                  </div>
                                  <div id="protoHint" class="ss-hint">После смены на сайте нажмите «Синхронизировать».</div>
                                </td>
                              </tr>
                              <tr>
                                <th data-ss-hint="Готовые наборы серверов с сайта (пакеты). Показывает название и статус: активен или на паузе.">Сборные подписки</th>
                                <td>
                                  <div class="ss-table-scroll"><table class="ss-data-table">
                                    <thead><tr><th>ID</th><th>Название</th><th>Статус</th></tr></thead>
                                    <tbody id="subsTable"></tbody>
                                  </table></div>
                                </td>
                              </tr>
                            </tbody>
                          </table>
                          <!-- keep configTable for legacy tests; hidden -->
                          <table style="display:none"><tbody id="configTable"></tbody></table>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_catalogModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
<div id="routingModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="routingModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="routingModalTitle">Routing</div>
                      <p class="ss-modal-summary">Пресеты, правила домен/geoip и JSON routing для dataplane.</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-routing">
<table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Routing</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%" data-ss-hint="Готовый набор правил одной кнопкой. Например: «весь трафик в VPN» или «Россия напрямую, остальное в VPN». Выберите пресет и нажмите «Применить».">Пресет</th>
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
                          <th data-ss-hint="Своё правило: что искать (сайт, страна, IP) и куда отправлять (в VPN или напрямую). Подсказки появятся, когда начнёте печатать название сайта.">Новое правило</th>
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
                              <input id="btnSaveRouting" class="button_gen button_gen_small" type="button" value="Сохранить routing">
                              <input id="btnGeodata" class="button_gen button_gen_small" type="button" value="Обновить geoip/geosite">
                            </div>
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Список уже действующих правил. Чем меньше номер приоритета — тем раньше правило срабатывает. Можно удалить ненужное.">Текущие правила</th>
                          <td>
                            <div class="ss-table-scroll"><table class="ss-data-table">
                              <thead>
                                <tr>
                                  <th>#</th><th>Имя</th><th>Тип</th><th>Matcher</th><th>Outbound</th><th>Prio</th><th></th>
                                </tr>
                              </thead>
                              <tbody id="rulesTable"></tbody>
                            </table></div>
                            <div class="ss-hint" style="margin-top:6px">
                              Outbound <code>ss-&lt;id&gt;</code> — VPN из API-ключа (включите конфиг на вкладке «Мои подключения»).
                              Geosite/geoip берутся из файлов после «Обновить geoip/geosite».
                            </div>
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Для опытных: правила в текстовом виде. Обычным пользователям достаточно пресетов и формы выше. Ошибка в JSON может сломать маршрутизацию.">JSON (дополнительно)</th>
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
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_routingModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
                  <div id="policiesModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="policiesModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="policiesModalTitle">Clients / MAC policies</div>
                      <p class="ss-modal-summary">Bypass / redirect по MAC. Список устройств подгружается автоматически при открытии.</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-policies">
<table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Clients / MAC policies</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%">Правила</th>
                          <td>
                            <div class="ss-hint">Нет правил → весь LAN в VPN. Есть правила → нужен catch-all redirect, иначе «дыра».</div>
                            <label style="color:#fff" data-ss-hint="Если есть правила для отдельных устройств, включите это: все остальные устройства дома тоже пойдут через VPN. Иначе устройства «без правила» могут уйти в интернет напрямую — получится дыра."><input id="policyCatchall" type="checkbox"> Catch-all redirect для остальных</label>
                            <input id="btnLoadClients" class="button_gen button_gen_small" type="button" value="Обновить" style="margin-left:8px" title="Обновить список без Apply (appGet)">
                            <div id="clientsStatus" class="ss-hint">Устройства загружаются автоматически…</div>
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Выберите устройство из списка, режим bypass/redirect, при желании ограничьте порты. Затем «Добавить» и «Сохранить политики», после — «Применить» внизу.">Добавить</th>
                          <td>
                            <select id="clientSelect" class="input_25_table"><option value="">— загрузка устройств —</option></select>
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
                              <input id="btnSavePolicies" class="button_gen button_gen_small" type="button" value="Сохранить политики">
                            </span>
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Список устройств с особыми правилами. Bypass — устройство ходит в интернет мимо VPN. Redirect — через VPN.">Таблица</th>
                          <td>
                            <div class="ss-table-scroll"><table class="ss-data-table">
                              <thead><tr><th>Mode</th><th>MAC</th><th>Имя</th><th>Ports</th><th>Proto</th><th></th></tr></thead>
                              <tbody id="policiesTable"></tbody>
                            </table></div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_policiesModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
                  <div id="generalModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="generalModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="generalModalTitle">Mode / DNS</div>
                      <p class="ss-modal-summary">Только dataplane mode и DNS. Ядро Xray — отдельный раздел «Xray core».</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-general">
<table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Mode / DNS</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%" data-ss-hint="Как роутер направляет трафик устройств. Proxy — только программы сами подключаются к SOCKS/HTTP. Redirect — автоматически для TCP. Tproxy — TCP и UDP (нужна поддержка в прошивке).">Dataplane mode</th>
                          <td>
                            <select id="modeSelect" class="input_32_table">
                              <option value="proxy">proxy (только SOCKS/HTTP, без LAN hijack)</option>
                              <option value="redirect">redirect (TCP transparent)</option>
                              <option value="tproxy">tproxy (TCP+UDP, нужен xt_TPROXY)</option>
                            </select>
                            <input id="btnSetMode" class="button_gen button_gen_small" type="button" value="В очередь" style="margin-left:6px">
                            <div class="ss-hint">После смены нажмите «Применить» внизу страницы.</div>
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Как обрабатываются адреса сайтов. OFF — как обычно у роутера. BYPASS — часть запросов мимо VPN. REDIRECT — запросы DNS тоже через защиту. Неверный режим может «сломать» открытие сайтов.">DNS mode</th>
                          <td>
                            <select id="dnsModeSelect" class="input_25_table">
                              <option value="OFF">OFF</option>
                              <option value="BYPASS">BYPASS (ipset bypass)</option>
                              <option value="REDIRECT">REDIRECT (hijack :53 → Xray)</option>
                            </select>
                            <input id="btnSetDns" class="button_gen button_gen_small" type="button" value="В очередь" style="margin-left:6px">
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Обновление ставит только пакет StealthSurf (UI/CLI/хуки). Geoip/geosite и бинарь Xray не перекачиваются — для них отдельные кнопки / ssurf geo / ssurf xray.">Версия аддона</th>
                          <td>
                            <span id="verDetailAdvanced" class="label label-muted">—</span>
                            <span class="row-buttons" style="margin-left:6px">
                              <input id="btnCheckUpdate2" class="button_gen button_gen_small" type="button" value="Проверить на GitHub">
                              <input id="btnForceUpdate" class="button_gen button_gen_small" type="button" value="Установить latest с GitHub">
                              <input id="btnVersions2" class="button_gen button_gen_small" type="button" value="Выбрать версию / откат">
                            </span>
                            <div class="ss-hint">
                              CLI: <code>ssurf cu</code> / <code>ssurf upd</code> / <code>ssurf lv</code> / <code>ssurf iv v1.0.16</code>.
                              Обновление аддона не трогает geoip — отдельно: <b>Обновить geoip/geosite</b> / <code>ssurf geo</code>. Ядро Xray — раздел <b>Xray core</b>.
                            </div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_generalModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
                  <div id="xrayModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="xrayModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="xrayModalTitle">Xray core</div>
                      <p class="ss-modal-summary">Ядро Xray — движок VPN на роутере. Без него конфиги StealthSurf не поднимутся. Релизы: GitHub XTLS/Xray-core (как в XrayUI).</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-xray">
<table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Xray core</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%" data-ss-hint="Что сейчас установлено на роутере: путь к бинарю и версия, которую отдаёт сам xray version.">Установлено</th>
                          <td>
                            <div id="xrayStatusBox" class="ss-hint">Проверяю…</div>
                            <span class="row-buttons" style="margin-top:6px">
                              <input id="btnXrayRefresh" class="button_gen button_gen_small" type="button" value="Обновить статус">
                              <input id="btnInstallXray" class="button_gen button_gen_small" type="button" value="Установить / найти Xray">
                            </span>
                            <div class="ss-hint">Сначала opkg, если нет — скачивание zip с GitHub под архитектуру роутера.</div>
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Список релизов Xray-core автоматически загружается с GitHub (api.github.com/repos/XTLS/Xray-core/releases), как в XrayUI. Можно поставить конкретную версию под архитектуру роутера.">Релизы GitHub</th>
                          <td>
                            <div class="ss-hint">Репозиторий: <a href="https://github.com/XTLS/Xray-core/releases" target="_blank" rel="noopener">XTLS/Xray-core</a> — список подтягивается сам при открытии раздела.</div>
                            <span class="row-buttons" style="margin:6px 0">
                              <input id="btnXrayVersions" class="button_gen button_gen_small" type="button" value="Обновить список">
                            </span>
                            <div class="ss-table-scroll"><table class="ss-data-table">
                              <thead><tr><th>Версия</th><th>Дата</th><th></th></tr></thead>
                              <tbody id="xrayVersionsTable"><tr><td colspan="3">Загрузка релизов Xray-core с GitHub…</td></tr></tbody>
                            </table></div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_xrayModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
                  <div id="backupModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="backupModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="backupModalTitle">Backup</div>
                      <p class="ss-modal-summary">Резервные копии conf / routing / policies. Логи аддона — отдельный раздел Logs.</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-backup">
<table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Backup</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%" data-ss-hint="Сделать снимок текущих настроек (конфиг, правила, ключи). Можно добавить короткую заметку. Ночной backup создаётся сам, если включён в General options.">Создать</th>
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
                          <th data-ss-hint="Уже сохранённые копии. Отсюда можно восстановить настройки «как было».">Список</th>
                          <td>
                            <div class="ss-table-scroll"><table class="ss-data-table">
                              <thead><tr><th>Файл</th><th>Когда</th><th>Заметка</th><th>Версия</th><th></th></tr></thead>
                              <tbody id="backupsTable"></tbody>
                            </table></div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_backupModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
                  <div id="logsModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="logsModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="logsModalTitle">Logs</div>
                      <p class="ss-modal-summary">Журнал работы аддона: действия, ошибки, устройства LAN и логи Xray.</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-logs">
<table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Logs</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%" data-ss-hint="Текстовый журнал: что делал аддон, ошибки, список устройств. Помогает понять, почему что-то не работает.">Просмотр</th>
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
                            <div id="logMeta" class="ss-hint">Выберите тип лога — при открытии окна подгружается activity.</div>
                            <div id="logBox" class="ss-logbox">(логи ещё не загружены)</div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_logsModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
                  <div id="diagModal" class="ss-modal" role="dialog" aria-modal="true" aria-labelledby="diagModalTitle">
                    <div class="ss-modal-card ss-wide-card">
                      <div class="ss-modal-head" id="diagModalTitle">Diagnostics</div>
                      <p class="ss-modal-summary">Diag dump, тест xray.json и проверка IP через SOCKS / напрямую.</p>
                      <div class="ss-modal-body">
                        <div class="ss-panel" id="tab-diag">
<table width="100%" border="0" align="center" cellpadding="4" cellspacing="0" class="FormTable">
                      <thead><tr><td colspan="2">Diagnostics</td></tr></thead>
                      <tbody>
                        <tr>
                          <th width="30%" data-ss-hint="Быстрые проверки. Diag dump — полный снимок для поддержки. Тест xray.json — конфиг собран правильно ли. IP через SOCKS — видит ли мир вас через VPN. IP напрямую — ваш обычный адрес.">Действия</th>
                          <td>
                            <span class="row-buttons">
                              <input id="btnDiag" class="button_gen button_gen_small" type="button" value="Снять diag dump">
                              <input id="btnTestCfg" class="button_gen button_gen_small" type="button" value="Тест xray.json">
                              <input id="btnConnSocks" class="button_gen button_gen_small" type="button" value="IP через SOCKS">
                              <input id="btnConnDirect" class="button_gen button_gen_small" type="button" value="IP напрямую">
                            </span>
                            <div class="ss-hint">Результаты появляются ниже. Логи программы — раздел <b>Logs</b>.</div>
                          </td>
                        </tr>
                        <tr>
                          <th data-ss-hint="Сюда выводится ответ после нажатия кнопок диагностики.">Результат</th>
                          <td><div id="diagBox" class="ss-logbox">Нажмите одну из кнопок выше — сюда придёт ответ с роутера.</div></td>
                        </tr>
                      </tbody>
                    </table>
                        </div>
                      </div>
                      <div class="ss-modal-actions">
                        <input id="btnClose_diagModal" class="button_gen button_gen_small" type="button" value="Закрыть">
                      </div>
                    </div>
                  </div>
                  <div class="apply_gen">
                    <input id="btnApplyAll" class="button_gen" type="button" value="Применить" disabled>
                    <input id="btnCancelAll" class="button_gen" type="button" value="Отменить" disabled style="margin-left:8px">
                    <div id="pendingChangesPanel" class="ss-pending">
                      <div class="ss-pending-title">Изменения к применению / откату</div>
                      <div id="pendingChangesList" class="ss-pending-list empty"><div class="ss-pending-empty">Нет изменений</div></div>
                    </div>
                  </div>
                  <div class="ss-version">
                    <a href="#" id="btnVersionFooter" title="Проверить обновление">STEALTHSURF <span id="footerVer">v—</span></a>
                  </div>

                  <div id="msg" class="ss-msg"></div>
                  </div>
                </td>
              </tr>
              </tbody>
            </table>
          </td>
        </tr>
        </tbody>
      </table>
    </td>
  </tr>
  </tbody>
</table>
</form>

<div id="footer"></div>
<div id="ssHelpTip" role="tooltip"></div>
<script type="text/javascript">
  // Paint TopBanner / left menu while jQuery `$` is still intact (app.js must not shadow it).
  try { initial(); } catch (e) {}
</script>
<script type="text/javascript" src="/ext/stealthsurf/routing-suggest.js?v=__SS_VERSION__"></script>
<script type="text/javascript" src="/ext/stealthsurf/app.js?v=__SS_VERSION__"></script>
</body>
</html>
