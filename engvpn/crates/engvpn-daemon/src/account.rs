use crate::paths::Paths;
use crate::state::{atomic_write_json, AppState};
use anyhow::Result;
use serde_json::{json, Value};
use std::fs;

fn valid_api_key(key: &str) -> bool {
    // stlth_<8 hex>_<24 hex>
    let Some(rest) = key.strip_prefix("stlth_") else {
        return false;
    };
    let mut parts = rest.split('_');
    let a = parts.next().unwrap_or("");
    let b = parts.next().unwrap_or("");
    parts.next().is_none()
        && a.len() == 8
        && b.len() == 24
        && a.chars().all(|c| c.is_ascii_hexdigit())
        && b.chars().all(|c| c.is_ascii_hexdigit())
}

pub fn account_path(paths: &Paths) -> std::path::PathBuf {
    paths.data.join("account.json")
}

pub fn read_account_file(paths: &Paths) -> Value {
    let path = account_path(paths);
    if !path.is_file() {
        return json!({});
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(json!({}))
}

pub fn write_account_file(paths: &Paths, doc: &Value) -> Result<()> {
    atomic_write_json(&account_path(paths), doc)
}

pub fn mask_key(key: &str) -> String {
    if key.len() < 12 {
        return String::new();
    }
    format!("{}…{}", &key[..10], &key[key.len().saturating_sub(4)..])
}

pub fn hydrate_account(snap: &mut Value, paths: &Paths) {
    let acc = read_account_file(paths);
    let key = acc.get("apiKey").and_then(|v| v.as_str()).unwrap_or("");
    let sub = acc
        .get("subscriptionUrl")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if let Some(account) = snap.get_mut("account").and_then(|v| v.as_object_mut()) {
        account.insert("apiKeySet".into(), json!(!key.is_empty()));
        let masked = if key.is_empty() {
            String::new()
        } else {
            mask_key(key)
        };
        account.insert("apiKeyMasked".into(), json!(masked));
        account.insert("subscriptionUrl".into(), json!(sub));
        if let Some(email) = acc.get("email") {
            account.insert("email".into(), email.clone());
        }
        if let Some(balance) = acc.get("balance") {
            account.insert("balance".into(), balance.clone());
        }
        account.insert("cloud".into(), json!(!key.is_empty()));
    }
}

pub async fn save_account(paths: &Paths, state: &mut AppState, body: &Value) -> Result<Value> {
    let clear = body.get("clearKey").and_then(|v| v.as_bool()).unwrap_or(false);
    let mut doc = read_account_file(paths);
    if clear {
        doc = json!({});
        write_account_file(paths, &doc)?;
        if let Some(a) = state.0.get_mut("account").and_then(|v| v.as_object_mut()) {
            a.insert("apiKeySet".into(), json!(false));
            a.insert("apiKeyMasked".into(), json!(""));
            a.insert("subscriptionUrl".into(), json!(""));
            a.insert("balance".into(), Value::Null);
            a.insert("cloud".into(), json!(false));
        }
        // reset nodes to direct-only
        reset_local_nodes(state);
        return Ok(json!({ "ok": true, "cleared": true }));
    }

    let mut did_key = false;
    if let Some(key) = body.get("apiKey").and_then(|v| v.as_str()) {
        let key = key.trim();
        if !key.is_empty() {
            if !valid_api_key(key) {
                anyhow::bail!("Неверный формат API-ключа (ожидается stlth_…)");
            }
            doc["apiKey"] = json!(key);
            did_key = true;
        }
    }
    if let Some(url) = body
        .get("subscriptionUrl")
        .or_else(|| body.get("url"))
        .and_then(|v| v.as_str())
    {
        let url = url.trim();
        doc["subscriptionUrl"] = json!(url);
        if !url.is_empty() && !did_key {
            ingest_subscription_url(state, url).await?;
        }
    }
    // Single share link in subscriptionUrl / link field
    if let Some(link) = body.get("link").and_then(|v| v.as_str()) {
        if link.contains("://") {
            ingest_share_link(state, link)?;
            doc["subscriptionUrl"] = json!(link);
        }
    }
    write_account_file(paths, &doc)?;
    // After saving API key — sync balance + configs from StealthSurf API
    if did_key {
        match sync_account(paths, state).await {
            Ok(r) => return Ok(json!({ "ok": true, "synced": true, "sync": r })),
            Err(e) => {
                // Key saved; sync failure is soft for offline routers
                return Ok(json!({ "ok": true, "synced": false, "syncError": e.to_string() }));
            }
        }
    }
    Ok(json!({ "ok": true }))
}

pub async fn sync_account(paths: &Paths, state: &mut AppState) -> Result<Value> {
    let doc = read_account_file(paths);
    let key = doc.get("apiKey").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if key.is_empty() {
        // Fall back to subscription URL refresh
        if let Some(url) = doc.get("subscriptionUrl").and_then(|v| v.as_str()) {
            if !url.is_empty() && (url.starts_with("http://") || url.starts_with("https://")) {
                ingest_subscription_url(state, url).await?;
                return Ok(json!({ "ok": true, "mode": "subscription" }));
            }
        }
        anyhow::bail!("Нет API-ключа и URL подписки");
    }
    let base = std::env::var("ENGVPN_SS_API").unwrap_or_else(|_| "https://api.stealthsurf.net".into());
    let base = base.trim_end_matches('/').to_string();
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent("engvpn/1.0")
        .build()?;
    // Prefer /profile (EngVPN/SS docs); fall back to /v1/me
    let me = {
        let mut resp = client
            .get(format!("{base}/profile"))
            .header("Authorization", format!("Bearer {key}"))
            .send()
            .await?;
        if !resp.status().is_success() {
            resp = client
                .get(format!("{base}/v1/me"))
                .header("Authorization", format!("Bearer {key}"))
                .send()
                .await?;
        }
        if !resp.status().is_success() {
            anyhow::bail!("StealthSurf API: HTTP {}", resp.status());
        }
        resp.json::<Value>().await.unwrap_or(json!({}))
    };
    let me_data = me.get("data").cloned().unwrap_or(me.clone());
    let balance = me_data
        .get("balance")
        .cloned()
        .unwrap_or(Value::Null);
    let email = me_data
        .get("email")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let configs = {
        let mut resp = client
            .get(format!("{base}/configs"))
            .header("Authorization", format!("Bearer {key}"))
            .send()
            .await?;
        if !resp.status().is_success() {
            resp = client
                .get(format!("{base}/v1/configs"))
                .header("Authorization", format!("Bearer {key}"))
                .send()
                .await?;
        }
        if resp.status().is_success() {
            resp.json().await.unwrap_or(json!([]))
        } else {
            json!([])
        }
    };
    let configs_json = configs.get("data").cloned().unwrap_or(configs);
    let nodes = configs_to_nodes(&configs_json);

    let mut doc = doc;
    doc["balance"] = balance.clone();
    doc["email"] = json!(email);
    write_account_file(paths, &doc)?;

    if let Some(a) = state.0.get_mut("account").and_then(|v| v.as_object_mut()) {
        a.insert("balance".into(), balance.clone());
        a.insert("email".into(), json!(email));
        a.insert("apiKeySet".into(), json!(true));
        a.insert("apiKeyMasked".into(), json!(mask_key(&key)));
        a.insert("cloud".into(), json!(true));
        a.insert("subscriptionName".into(), json!("Основная подписка (API)"));
    }
    set_ss_api_nodes(state, nodes);
    let n = state
        .0
        .get("subscriptions")
        .and_then(|v| v.as_array())
        .and_then(|a| a.iter().find(|s| s.get("id").and_then(|i| i.as_str()) == Some("ss-api")))
        .and_then(|s| s.get("nodes").and_then(|n| n.as_array()))
        .map(|a| a.iter().filter(|n| n.get("protocol").and_then(|p| p.as_str()) != Some("direct")).count())
        .unwrap_or(0);
    Ok(json!({ "ok": true, "mode": "api", "nodes": n, "balance": balance, "email": email }))
}

fn configs_to_nodes(configs: &Value) -> Vec<Value> {
    let arr = if let Some(a) = configs.as_array() {
        a.clone()
    } else if let Some(a) = configs.get("data").and_then(|v| v.as_array()) {
        a.clone()
    } else if let Some(a) = configs.get("configs").and_then(|v| v.as_array()) {
        a.clone()
    } else {
        vec![]
    };
    let mut nodes = vec![json!({
        "id": "direct",
        "name": "Без VPN",
        "protocol": "direct",
        "country": "",
        "flag": "direct",
        "until": "",
        "online": true
    })];
    for (i, c) in arr.iter().enumerate() {
        if c.is_null() {
            continue;
        }
        let id = c
            .get("id")
            .map(|v| match v {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                _ => format!("ss-{i}"),
            })
            .unwrap_or_else(|| format!("ss-{i}"));
        let name = c
            .get("name")
            .or_else(|| c.get("title"))
            .and_then(|v| v.as_str())
            .unwrap_or("Сервер");
        let protocol = c
            .get("protocol")
            .and_then(|v| v.as_str())
            .unwrap_or("vless");
        let country = c
            .get("country")
            .or_else(|| c.get("flag"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let share = c
            .get("connection_url")
            .or_else(|| c.get("share"))
            .cloned()
            .unwrap_or(Value::Null);
        let mut node = json!({
            "id": id,
            "name": name,
            "protocol": protocol,
            "country": country,
            "flag": country,
            "online": c.get("is_online").and_then(|v| v.as_bool()).unwrap_or(true),
            "cloud": true,
        });
        if !share.is_null() {
            if let Some(obj) = node.as_object_mut() {
                obj.insert("share".into(), share);
            }
        }
        if let Some(obj) = node.as_object_mut() {
            if let Some(cobj) = c.as_object() {
                for (k, v) in cobj {
                    if !obj.contains_key(k) {
                        obj.insert(k.clone(), v.clone());
                    }
                }
            }
        }
        nodes.push(node);
    }
    nodes
}

fn set_subscription_nodes(state: &mut AppState, nodes: Vec<Value>) {
    if let Some(subs) = state.0.get_mut("subscriptions").and_then(|v| v.as_array_mut()) {
        if let Some(main) = subs.get_mut(0) {
            main["nodes"] = Value::Array(nodes);
        }
    }
}

/// StealthSurf API configs → dedicated `ss-api` subscription (UI + smoke expect this id).
fn set_ss_api_nodes(state: &mut AppState, nodes: Vec<Value>) {
    let vpn_count = nodes
        .iter()
        .filter(|n| n.get("protocol").and_then(|p| p.as_str()) != Some("direct"))
        .count();
    let first_vpn = nodes
        .iter()
        .find(|n| n.get("protocol").and_then(|p| p.as_str()) != Some("direct"))
        .and_then(|n| n.get("id").cloned());

    if let Some(subs) = state.0.get_mut("subscriptions").and_then(|v| v.as_array_mut()) {
        if let Some(existing) = subs
            .iter_mut()
            .find(|s| s.get("id").and_then(|i| i.as_str()) == Some("ss-api"))
        {
            existing["name"] = json!(format!("StealthSurf API ({vpn_count})"));
            existing["nodes"] = Value::Array(nodes.clone());
            existing["source"] = json!("stealthsurf-api");
            existing["updatedAt"] = json!(now_ms());
        } else {
            subs.push(json!({
                "id": "ss-api",
                "name": format!("StealthSurf API ({vpn_count})"),
                "url": "",
                "nodes": nodes,
                "builtin": false,
                "source": "stealthsurf-api",
                "updatedAt": now_ms(),
            }));
        }
    }
    state.0["activeSubscription"] = json!("ss-api");
    if let Some(id) = first_vpn {
        let still_valid = state
            .0
            .get("vpn")
            .and_then(|v| v.get("selectedId"))
            .and_then(|v| v.as_str())
            .map(|sel| {
                state
                    .0
                    .get("subscriptions")
                    .and_then(|s| s.as_array())
                    .and_then(|arr| {
                        arr.iter()
                            .find(|s| s.get("id").and_then(|i| i.as_str()) == Some("ss-api"))
                    })
                    .and_then(|s| s.get("nodes").and_then(|n| n.as_array()))
                    .map(|nodes| {
                        nodes.iter().any(|n| n.get("id").and_then(|i| i.as_str()) == Some(sel))
                    })
                    .unwrap_or(false)
            })
            .unwrap_or(false);
        if !still_valid {
            if let Some(vpn) = state.0.get_mut("vpn").and_then(|v| v.as_object_mut()) {
                vpn.insert("selectedId".into(), id.clone());
                vpn.insert("lastVpnId".into(), id);
            }
        }
    }
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn reset_local_nodes(state: &mut AppState) {
    set_subscription_nodes(
        state,
        vec![json!({
            "id": "direct",
            "name": "Без VPN",
            "protocol": "direct",
            "country": "",
            "flag": "direct",
            "until": "",
            "online": true
        })],
    );
    state.0["vpn"]["selectedId"] = json!("direct");
    state.0["vpn"]["connected"] = json!(false);
}

async fn ingest_subscription_url(state: &mut AppState, url: &str) -> Result<()> {
    if url.starts_with("vless://")
        || url.starts_with("trojan://")
        || url.starts_with("ss://")
        || url.starts_with("hysteria2://")
        || url.starts_with("hy2://")
    {
        return ingest_share_link(state, url);
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent("engvpn/1.0")
        .build()?;
    let text = client.get(url).send().await?.text().await?;
    // base64 or plain lines
    let decoded = decode_maybe_b64(&text);
    let mut nodes = vec![json!({
        "id": "direct",
        "name": "Без VPN",
        "protocol": "direct",
        "country": "",
        "flag": "direct",
        "online": true
    })];
    for (i, line) in decoded.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(n) = parse_share_link(line, i) {
            nodes.push(n);
        }
    }
    set_subscription_nodes(state, nodes);
    Ok(())
}

fn ingest_share_link(state: &mut AppState, link: &str) -> Result<()> {
    let mut nodes = vec![json!({
        "id": "direct",
        "name": "Без VPN",
        "protocol": "direct",
        "country": "",
        "flag": "direct",
        "online": true
    })];
    if let Some(n) = parse_share_link(link, 0) {
        nodes.push(n);
    }
    set_subscription_nodes(state, nodes);
    Ok(())
}

fn decode_maybe_b64(text: &str) -> String {
    let t = text.trim();
    if t.contains("://") {
        return t.to_string();
    }
    use base64::Engine;
    if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(t) {
        return String::from_utf8_lossy(&bytes).to_string();
    }
    if let Ok(bytes) = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(t) {
        return String::from_utf8_lossy(&bytes).to_string();
    }
    t.to_string()
}

fn parse_share_link(link: &str, idx: usize) -> Option<Value> {
    let link = link.trim();
    if link.starts_with("vless://") {
        let rest = link.trim_start_matches("vless://");
        let name = link
            .rsplit('#')
            .next()
            .map(|s| urlencoding_decode(s))
            .filter(|s| !s.is_empty() && !s.contains("://"))
            .unwrap_or_else(|| format!("VLESS {idx}"));
        return Some(json!({
            "id": format!("vless-{idx}"),
            "name": name,
            "protocol": "vless",
            "share": link,
            "online": true,
            "raw": rest,
        }));
    }
    if link.starts_with("trojan://") {
        let name = link
            .rsplit('#')
            .next()
            .map(|s| urlencoding_decode(s))
            .filter(|s| !s.is_empty() && !s.contains("://"))
            .unwrap_or_else(|| format!("Trojan {idx}"));
        return Some(json!({
            "id": format!("trojan-{idx}"),
            "name": name,
            "protocol": "trojan",
            "share": link,
            "online": true,
        }));
    }
    if link.starts_with("ss://") {
        return Some(json!({
            "id": format!("ss-{idx}"),
            "name": format!("Shadowsocks {idx}"),
            "protocol": "shadowsocks",
            "share": link,
            "online": true,
        }));
    }
    if link.starts_with("hysteria2://") || link.starts_with("hy2://") {
        return Some(json!({
            "id": format!("hy2-{idx}"),
            "name": format!("Hysteria {idx}"),
            "protocol": "hysteria2",
            "share": link,
            "online": true,
        }));
    }
    None
}

fn urlencoding_decode(s: &str) -> String {
    // minimal %XX decode
    let mut out = String::new();
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = &s[i + 1..i + 3];
            if let Ok(v) = u8::from_str_radix(hex, 16) {
                out.push(v as char);
                i += 3;
                continue;
            }
        }
        out.push(b[i] as char);
        i += 1;
    }
    out
}
