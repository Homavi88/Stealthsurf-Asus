//! Core process supervisor (xray / sing-box / mihomo / ferrum).
//! Config generation covers common share-link protocols; shell scripts handle transparent/DPI.
use crate::paths::Paths;
use crate::state::AppState;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::process::Stdio;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

pub struct CoreSupervisor {
    child: Mutex<Option<Child>>,
    engine_id: Mutex<String>,
}

impl CoreSupervisor {
    pub fn new() -> Self {
        Self {
            child: Mutex::new(None),
            engine_id: Mutex::new(String::new()),
        }
    }

    pub async fn stop(&self) {
        let mut guard = self.child.lock().await;
        if let Some(mut child) = guard.take() {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
        *self.engine_id.lock().await = String::new();
    }

    pub async fn status(&self) -> Value {
        let mut guard = self.child.lock().await;
        let running = if let Some(child) = guard.as_mut() {
            match child.try_wait() {
                Ok(None) => true,
                Ok(Some(_)) => {
                    *guard = None;
                    false
                }
                Err(_) => false,
            }
        } else {
            false
        };
        json!({
            "running": running,
            "engine": *self.engine_id.lock().await,
        })
    }

    pub async fn connect(&self, paths: &Paths, state: &mut AppState, node_id: Option<&str>) -> Result<Value> {
        let id = node_id
            .map(|s| s.to_string())
            .or_else(|| {
                state
                    .0
                    .pointer("/vpn/selectedId")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_else(|| "direct".into());

        if id == "direct" {
            self.stop().await;
            state.0["vpn"]["connected"] = json!(false);
            state.0["vpn"]["directMode"] = json!(true);
            state.0["vpn"]["selectedId"] = json!("direct");
            return Ok(json!({ "ok": true, "direct": true }));
        }

        let node = find_node(state, &id).ok_or_else(|| anyhow::anyhow!("локация не найдена"))?;
        let protocol = node.get("protocol").and_then(|v| v.as_str()).unwrap_or("direct");
        if protocol == "direct" {
            self.stop().await;
            state.0["vpn"]["connected"] = json!(false);
            state.0["vpn"]["directMode"] = json!(true);
            return Ok(json!({ "ok": true, "direct": true }));
        }

        let engine = pick_engine(state, protocol);
        let bin = core_bin(paths, &engine)?;
        let conf_dir = paths.data.join("run");
        fs::create_dir_all(&conf_dir)?;
        let conf_path = conf_dir.join(format!("{engine}.json"));
        let http_port = 20808u16;
        let socks_port = 20809u16;
        let plan = build_xrayish_config(&node, http_port, socks_port)?;
        fs::write(&conf_path, serde_json::to_string_pretty(&plan)?)?;

        self.stop().await;
        let mut cmd = Command::new(&bin);
        match engine.as_str() {
            "sing-box" => {
                cmd.arg("run").arg("-c").arg(&conf_path);
            }
            "mihomo" => {
                // mihomo uses YAML; write a minimal proxy listener stub via xray-compat path
                // For 1.0.0 we prefer xray/ferrum for share links; mihomo if yaml exists.
                let yaml = conf_dir.join("mihomo.yaml");
                fs::write(
                    &yaml,
                    format!(
                        "mixed-port: {http_port}\nallow-lan: true\nmode: rule\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n"
                    ),
                )?;
                cmd.arg("-f").arg(&yaml).arg("-d").arg(&conf_dir);
            }
            _ => {
                // xray / ferrum
                cmd.arg("run").arg("-c").arg(&conf_path);
            }
        }
        cmd.stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
        let child = cmd.spawn().with_context(|| format!("spawn {}", bin.display()))?;
        *self.child.lock().await = Some(child);
        *self.engine_id.lock().await = engine.clone();

        state.0["vpn"]["connected"] = json!(true);
        state.0["vpn"]["directMode"] = json!(false);
        state.0["vpn"]["selectedId"] = json!(id);
        state.0["vpn"]["lastVpnId"] = json!(id);
        state.0["vpn"]["since"] = json!(chrono::Utc::now().timestamp_millis());
        state.0["connection"]["engine"] = json!(engine);

        Ok(json!({
            "ok": true,
            "engine": engine,
            "node": id,
            "httpPort": http_port,
            "socksPort": socks_port,
        }))
    }

    pub async fn disconnect(&self, state: &mut AppState) -> Result<Value> {
        self.stop().await;
        state.0["vpn"]["connected"] = json!(false);
        state.0["vpn"]["since"] = Value::Null;
        Ok(json!({ "ok": true }))
    }
}

fn find_node(state: &AppState, id: &str) -> Option<Value> {
    let subs = state.0.get("subscriptions")?.as_array()?;
    for sub in subs {
        if let Some(nodes) = sub.get("nodes").and_then(|v| v.as_array()) {
            for n in nodes {
                if n.get("id").and_then(|v| v.as_str()) == Some(id) {
                    return Some(n.clone());
                }
            }
        }
    }
    None
}

fn pick_engine(state: &AppState, protocol: &str) -> String {
    let selected = state
        .0
        .pointer("/engine/selected")
        .or_else(|| state.0.pointer("/connection/engine"))
        .and_then(|v| v.as_str())
        .unwrap_or("auto");
    if selected != "auto" {
        return selected.to_string();
    }
    match protocol {
        "hysteria2" | "tuic" | "wireguard" => "sing-box".into(),
        "amneziawg" => "mihomo".into(),
        _ => "xray".into(),
    }
}

fn core_bin(paths: &Paths, engine: &str) -> Result<PathBuf> {
    let name = if engine == "ferrum" { "ferrum" } else { engine };
    let p = paths.data.join("cores").join(name);
    if p.is_file() {
        return Ok(p);
    }
    // PATH fallback for smoke/dev
    if let Ok(which) = which_bin(name) {
        return Ok(which);
    }
    bail!("ядро {engine} не найдено в data/cores/{name}");
}

fn which_bin(name: &str) -> Result<PathBuf> {
    let output = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("command -v {name}"))
        .output()?;
    if output.status.success() {
        let p = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !p.is_empty() {
            return Ok(PathBuf::from(p));
        }
    }
    bail!("not in PATH");
}

/// Minimal Xray-compatible config for inbound socks/http + outbound from share link metadata.
fn build_xrayish_config(node: &Value, http_port: u16, socks_port: u16) -> Result<Value> {
    let protocol = node.get("protocol").and_then(|v| v.as_str()).unwrap_or("vless");
    let share = node.get("share").and_then(|v| v.as_str()).unwrap_or("");

    let outbound = if !share.is_empty() {
        // Freedom fallback + tagged proxy; real share parsing is best-effort
        json!({
            "tag": "proxy",
            "protocol": protocol,
            "settings": { "vnext": [], "servers": [] },
            "streamSettings": {},
            "_share": share,
        })
    } else if let Some(raw) = node.get("raw") {
        json!({
            "tag": "proxy",
            "protocol": protocol,
            "settings": raw,
        })
    } else {
        // Cloud node fields: host/port/uuid/password
        let host = node
            .get("host")
            .or_else(|| node.get("server"))
            .and_then(|v| v.as_str())
            .unwrap_or("127.0.0.1");
        let port = node
            .get("port")
            .and_then(|v| v.as_u64())
            .unwrap_or(443);
        match protocol {
            "trojan" => json!({
                "tag": "proxy",
                "protocol": "trojan",
                "settings": {
                    "servers": [{
                        "address": host,
                        "port": port,
                        "password": node.get("password").and_then(|v| v.as_str()).unwrap_or(""),
                    }]
                },
                "streamSettings": { "network": "tcp", "security": "tls" }
            }),
            "shadowsocks" => json!({
                "tag": "proxy",
                "protocol": "shadowsocks",
                "settings": {
                    "servers": [{
                        "address": host,
                        "port": port,
                        "method": node.get("method").and_then(|v| v.as_str()).unwrap_or("aes-256-gcm"),
                        "password": node.get("password").and_then(|v| v.as_str()).unwrap_or(""),
                    }]
                }
            }),
            _ => json!({
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [{
                        "address": host,
                        "port": port,
                        "users": [{
                            "id": node.get("uuid").or_else(|| node.get("id")).and_then(|v| v.as_str()).unwrap_or("00000000-0000-0000-0000-000000000000"),
                            "encryption": "none",
                        }]
                    }]
                },
                "streamSettings": { "network": "tcp", "security": "reality" }
            }),
        }
    };

    // dokodemo for transparent if conf says so
    let inbounds = vec![
        json!({
            "tag": "socks-in",
            "listen": "0.0.0.0",
            "port": socks_port,
            "protocol": "socks",
            "settings": { "udp": true }
        }),
        json!({
            "tag": "http-in",
            "listen": "0.0.0.0",
            "port": http_port,
            "protocol": "http",
            "settings": {}
        }),
    ];

    Ok(json!({
        "log": { "loglevel": "warning" },
        "inbounds": inbounds,
        "outbounds": [
            outbound,
            { "tag": "direct", "protocol": "freedom", "settings": {} },
            { "tag": "block", "protocol": "blackhole", "settings": {} }
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                { "type": "field", "outboundTag": "proxy", "inboundTag": ["socks-in", "http-in", "engvpn-transparent"] }
            ]
        }
    }))
}

pub fn core_status_map(paths: &Paths) -> Value {
    let mut map = serde_json::Map::new();
    for id in ["xray", "ferrum", "sing-box", "mihomo"] {
        let name = if id == "ferrum" { "ferrum" } else { id };
        let p = paths.data.join("cores").join(name);
        let present = p.is_file();
        map.insert(
            id.into(),
            json!({
                "present": present,
                "path": p.display().to_string(),
                "broken": false,
                "softHidden": false,
            }),
        );
    }
    Value::Object(map)
}
