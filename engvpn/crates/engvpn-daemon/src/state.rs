use crate::paths::Paths;
use anyhow::{Context, Result};
use pbkdf2::pbkdf2_hmac;
use rand::RngCore;
use serde_json::{json, Map, Value};
use sha2::Sha256;
use std::fs;
use std::path::Path;
use uuid::Uuid;

pub const PBKDF2_ITERATIONS: u32 = 120_000;
pub const DEFAULT_PANEL_PASSWORD: &str = "changeme";

#[derive(Clone, Debug)]
pub struct AppState(pub Value);

impl AppState {
    pub fn sessions_mut(&mut self) -> Option<&mut Map<String, Value>> {
        if !self.0.get("sessions").map(|v| v.is_object()).unwrap_or(false) {
            self.0["sessions"] = json!({});
        }
        self.0.get_mut("sessions").and_then(|v| v.as_object_mut())
    }

    pub fn public_snapshot(&self) -> Value {
        let mut snap = self.0.clone();
        if let Some(obj) = snap.as_object_mut() {
            obj.remove("password");
            obj.remove("sessions");
        }
        snap
    }
}

pub fn hash_password(password: &str) -> Value {
    let mut salt_bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut salt_bytes);
    let salt = hex::encode(salt_bytes);
    let mut hash = [0u8; 32];
    pbkdf2_hmac::<Sha256>(password.trim().as_bytes(), salt.as_bytes(), PBKDF2_ITERATIONS, &mut hash);
    json!({
        "salt": salt,
        "hash": hex::encode(hash),
        "algo": "pbkdf2-sha256",
        "iterations": PBKDF2_ITERATIONS,
    })
}

pub fn check_password(password: &str, stored: &Value) -> bool {
    let salt = stored.get("salt").and_then(|v| v.as_str()).unwrap_or("");
    let hash_hex = stored.get("hash").and_then(|v| v.as_str()).unwrap_or("");
    if salt.is_empty() || hash_hex.is_empty() {
        return false;
    }
    let pass = password.trim();
    if pass.is_empty() {
        return false;
    }
    let iter = stored
        .get("iterations")
        .and_then(|v| v.as_u64())
        .unwrap_or(PBKDF2_ITERATIONS as u64) as u32;
    let mut out = [0u8; 32];
    pbkdf2_hmac::<Sha256>(pass.as_bytes(), salt.as_bytes(), iter, &mut out);
    let Ok(prev) = hex::decode(hash_hex) else {
        return false;
    };
    if prev.len() != out.len() {
        return false;
    }
    // constant-time compare
    let mut diff = 0u8;
    for (a, b) in prev.iter().zip(out.iter()) {
        diff |= a ^ b;
    }
    diff == 0
}

pub fn default_state(version: &str) -> AppState {
    let mem_gb = ((total_mem_bytes() as f64) / (1024.0 * 1024.0 * 1024.0)).round().max(1.0) as u64;
    AppState(json!({
        "version": version,
        "createdAt": now_ms(),
        "password": hash_password(DEFAULT_PANEL_PASSWORD),
        "failedLogins": 0,
        "lockedUntil": 0,
        "sessions": {},
        "routerId": Uuid::new_v4().to_string(),
        "account": {
            "email": "",
            "balance": null,
            "subscriptionName": "Локальные подписки",
            "subscriptionUrl": "",
            "apiKeySet": false,
            "apiKeyMasked": "",
            "cloud": false,
            "nextCharge": "",
            "consoleUrl": "",
            "consoleConnected": false,
            "inviteCode": "",
        },
        "vpn": {
            "connected": false,
            "directMode": false,
            "since": null,
            "selectedId": "direct",
            "lastVpnId": "",
            "autoSetupToggle": false,
            "exitIp": "",
            "exitCountry": "",
            "pausedBySchedule": false,
        },
        "subscriptions": [{
            "id": "main",
            "name": "Локальные",
            "url": "",
            "builtin": true,
            "nodes": [{
                "id": "direct",
                "name": "Без VPN",
                "protocol": "direct",
                "country": "",
                "flag": "direct",
                "until": "",
                "online": true
            }]
        }],
        "activeSubscription": "main",
        "router": {
            "mode": "except",
            "transparentMethod": "auto",
            "dnsViaVpn": true,
            "blockQuic": false,
            "dnsLock": true,
            "gamesDirect": false,
            "blockWithoutVpn": false,
            "ipv6": "block",
            "adblock": true,
            "adCustom": [],
            "adWhitelist": [],
            "adExcludeDevices": [],
            "adStats": { "blocked": 0, "allowed": 0 },
            "trips": false,
            "captive": false,
            "ha": false,
            "mqtt": { "host": "", "port": 1883, "username": "", "password": "" },
            "scheduleEnabled": false,
            "scheduleHours": (0..24).map(|_| true).collect::<Vec<_>>(),
            "reserveId": "",
        },
        "network": {
            "youtubeZapret": false,
            "discordZapret": false,
            "zapret": { "lastCheck": 0, "checking": false, "note": "" },
        },
        "connection": {
            "engine": "auto",
            "warpMode": "off",
            "warpMethod": "wireguard",
            "warpProfile": null,
            "ipv4Only": true,
        },
        "engine": {
            "selected": "auto",
            "cores": {},
            "geo": { "geosite": 0, "geoip": 0, "updatedAt": 0 },
            "geoSource": "loyalsoldier",
            "geoUrl": "",
        },
        "routing": {
            "blockAds": true,
            "blockQuic": false,
            "games": false,
            "rules": [],
        },
        "updates": {
            "auto": false,
            "windowStart": 2,
            "windowEnd": 5,
            "geoWeekly": true,
            "coresWhenMissing": true,
            "interval": "1d",
            "lastCheck": 0,
            "latest": version,
            "available": false,
            "notes": "EngVPN обновляется из своего feed (SHA-256 + Minisign) через engvpnd update. Расписание — Merlin cru.",
        },
        "devices": [],
        "diagnostics": { "showLoad": true },
        "theme": "dark",
        "accent": "engvpn",
        "oled": false,
        "logs": [],
        "firmware": format!("{} / EngVPN", std::env::consts::OS),
        "hardware": {
            "hostname": hostname(),
            "arch": std::env::consts::ARCH,
            "ramGb": mem_gb,
        },
        "smartdns": { "enabled": false, "entries": [] },
        "runtime": {
            "load": { "cpu": 0.0, "ramUsed": 0, "ramTotal": 0, "proc": 0, "uptime": 0, "panelUptime": 0 },
            "uptime": 0,
            "panelUptime": 0,
            "cores": {},
            "download": null,
        },
    }))
}

pub fn load_state(paths: &Paths) -> Result<AppState> {
    let path = paths.state_path();
    if !path.is_file() {
        let st = default_state(&paths.installed_version());
        save_state(paths, &st)?;
        return Ok(st);
    }
    let raw = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    let mut value: Value = serde_json::from_str(&raw).unwrap_or_else(|_| default_state(&paths.installed_version()).0);
    // Ensure required keys
    if value.get("sessions").is_none() {
        value["sessions"] = json!({});
    }
    if value.get("password").is_none() {
        value["password"] = hash_password(DEFAULT_PANEL_PASSWORD);
    }
    let ver = paths.installed_version();
    value["version"] = json!(ver);
    Ok(AppState(value))
}

pub fn save_state(paths: &Paths, state: &AppState) -> Result<()> {
    let path = paths.state_path();
    atomic_write_json(&path, &state.0)
}

pub fn atomic_write_json(path: &Path, value: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.new");
    let body = serde_json::to_string_pretty(value)?;
    fs::write(&tmp, format!("{body}\n"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600));
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

pub fn set_path(state: &mut AppState, path: &str, value: Value) -> Result<(), String> {
    let parts: Vec<&str> = path.split('.').filter(|p| !p.is_empty()).collect();
    if parts.is_empty() {
        return Err("пустой путь".into());
    }
    for p in &parts {
        if *p == "__proto__" || *p == "constructor" || *p == "prototype" {
            return Err("Недопустимый путь".into());
        }
    }
    let mut cur = &mut state.0;
    for (i, part) in parts.iter().enumerate() {
        if i + 1 == parts.len() {
            if let Some(obj) = cur.as_object_mut() {
                obj.insert((*part).to_string(), value);
                return Ok(());
            }
            return Err("путь не объект".into());
        }
        if cur.get(part).is_none() {
            cur[part] = json!({});
        }
        cur = cur.get_mut(part).ok_or_else(|| "путь".to_string())?;
    }
    Ok(())
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn total_mem_bytes() -> u64 {
    #[cfg(target_os = "linux")]
    {
        if let Ok(s) = fs::read_to_string("/proc/meminfo") {
            for line in s.lines() {
                if let Some(rest) = line.strip_prefix("MemTotal:") {
                    let kb: u64 = rest.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0);
                    return kb * 1024;
                }
            }
        }
    }
    256 * 1024 * 1024
}

fn hostname() -> String {
    fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "engvpn".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_path_blocks_proto() {
        let mut st = default_state("1.0.0");
        assert!(set_path(&mut st, "router.__proto__.x", json!(1)).is_err());
    }
}
