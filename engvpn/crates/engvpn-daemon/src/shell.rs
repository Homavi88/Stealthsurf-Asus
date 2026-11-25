//! Shell-out helpers to share/engvpn/*.sh and engvpnd.
use crate::paths::Paths;
use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::process::Stdio;
use tokio::process::Command;

pub async fn run_script(paths: &Paths, script: &str, args: &[&str]) -> Result<Value> {
    let path = paths.share.join(script);
    if !path.is_file() {
        anyhow::bail!("нет {script}");
    }
    let output = Command::new("sh")
        .arg(&path)
        .args(args)
        .env("ENGVPN_DATA_DIR", &paths.data)
        .env("ENGVPN_PREFIX", &paths.prefix)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .with_context(|| format!("exec {script}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    Ok(json!({
        "ok": output.status.success(),
        "code": output.status.code().unwrap_or(1),
        "output": stdout.trim(),
        "stderr": stderr.trim(),
        "stdout": stdout,
    }))
}

pub async fn run_engvpnd(paths: &Paths, args: &[&str]) -> Result<Value> {
    let bin = if paths.engvpnd.is_file() {
        paths.engvpnd.clone()
    } else {
        std::path::PathBuf::from("engvpnd")
    };
    let output = Command::new(&bin)
        .args(args)
        .env("ENGVPN_DATA_DIR", &paths.data)
        .env("ENGVPN_PREFIX", &paths.prefix)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .with_context(|| format!("engvpnd {}", args.join(" ")))?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    Ok(json!({
        "ok": output.status.success(),
        "code": output.status.code().unwrap_or(1),
        "output": stdout.trim(),
        "stderr": stderr.trim(),
        "stdout": stdout,
    }))
}

pub fn write_kv_conf(path: &std::path::Path, partial: &[(String, String)]) -> Result<Value> {
    use std::collections::BTreeMap;
    let mut cur: BTreeMap<String, String> = BTreeMap::new();
    if path.is_file() {
        if let Ok(raw) = std::fs::read_to_string(path) {
            for line in raw.lines() {
                if let Some((k, v)) = line.split_once('=') {
                    if k.chars().all(|c| c.is_ascii_lowercase() || c == '_') {
                        cur.insert(k.to_string(), v.to_string());
                    }
                }
            }
        }
    }
    for (k, v) in partial {
        cur.insert(k.clone(), v.clone());
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let body = cur
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(path, format!("{body}\n"))?;
    Ok(json!(cur))
}

pub fn read_kv_conf(path: &std::path::Path) -> Value {
    let mut map = serde_json::Map::new();
    if let Ok(raw) = std::fs::read_to_string(path) {
        for line in raw.lines() {
            if let Some((k, v)) = line.split_once('=') {
                map.insert(k.to_string(), json!(v));
            }
        }
    }
    Value::Object(map)
}
