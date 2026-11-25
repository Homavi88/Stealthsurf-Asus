use crate::paths::Paths;
use crate::state::{hash_password, load_state, save_state, check_password, AppState};
use anyhow::{bail, Result};
use rand::RngCore;
use std::io::{self, Read};
use std::time::{SystemTime, UNIX_EPOCH};

const SESSION_TTL_MS: u64 = 14 * 86400 * 1000;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn issue_session(state: &mut AppState) -> String {
    let mut bytes = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut bytes);
    let token = hex::encode(bytes);
    let exp = now_ms() + SESSION_TTL_MS;
    if let Some(obj) = state.sessions_mut() {
        obj.insert(token.clone(), serde_json::json!({ "exp": exp }));
    }
    token
}

pub fn session_ok(state: &mut AppState, token: &str) -> bool {
    if token.is_empty() {
        return false;
    }
    let Some(sessions) = state.0.get_mut("sessions").and_then(|v| v.as_object_mut()) else {
        return false;
    };
    let Some(row) = sessions.get(token) else {
        return false;
    };
    let exp = row.get("exp").and_then(|v| v.as_u64()).unwrap_or(0);
    if exp < now_ms() {
        sessions.remove(token);
        return false;
    }
    true
}

pub fn login(state: &mut AppState, password: &str, open_panel: bool) -> Result<String, (u16, String)> {
    if open_panel {
        state.0["failedLogins"] = serde_json::json!(0);
        state.0["lockedUntil"] = serde_json::json!(0);
        return Ok(issue_session(state));
    }
    let locked = state.0.get("lockedUntil").and_then(|v| v.as_u64()).unwrap_or(0);
    if locked > now_ms() {
        return Err((429, "Слишком много попыток, подождите минуту".into()));
    }
    let pass = password.trim();
    if pass.is_empty() {
        return Err((401, "Введите пароль".into()));
    }
    let stored = state.0.get("password").cloned().unwrap_or(serde_json::Value::Null);
    if !check_password(pass, &stored) {
        let fails = state.0.get("failedLogins").and_then(|v| v.as_u64()).unwrap_or(0) + 1;
        state.0["failedLogins"] = serde_json::json!(fails);
        if fails >= 8 {
            state.0["lockedUntil"] = serde_json::json!(now_ms() + 60_000);
            state.0["failedLogins"] = serde_json::json!(0);
        }
        return Err((401, "Неверный пароль. Сброс: engvpnd set-password".into()));
    }
    state.0["failedLogins"] = serde_json::json!(0);
    state.0["lockedUntil"] = serde_json::json!(0);
    Ok(issue_session(state))
}

pub fn logout(state: &mut AppState, token: &str, open_panel: bool) {
    if open_panel {
        return;
    }
    if let Some(sessions) = state.0.get_mut("sessions").and_then(|v| v.as_object_mut()) {
        sessions.remove(token);
    }
}

fn validate_password(password: &str) -> Result<()> {
    let len = password.chars().count();
    if len < 8 || len > 128 {
        bail!("password must be 8–128 characters");
    }
    for ch in password.chars() {
        let code = ch as u32;
        if code < 0x20 || code == 0x7f || (0x80..=0x9f).contains(&code) {
            bail!("password must not contain control characters");
        }
    }
    Ok(())
}

pub fn set_password_from_stdin(paths: &Paths) -> Result<()> {
    paths.ensure_writable_data()?;
    let mut raw = String::new();
    io::stdin().read_to_string(&mut raw)?;
    if raw.ends_with('\n') {
        raw.pop();
        if raw.ends_with('\r') {
            raw.pop();
        }
    }
    validate_password(&raw)?;
    let mut state = load_state(paths)?;
    state.0["password"] = hash_password(&raw);
    state.0["openAccess"] = serde_json::json!(false);
    if state.0.get("version").and_then(|v| v.as_str()).unwrap_or("").is_empty() {
        state.0["version"] = serde_json::json!(paths.installed_version());
    }
    save_state(paths, &state)?;
    let _ = std::fs::remove_file(paths.data.join("open-panel"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::hash_password;

    #[test]
    fn password_roundtrip() {
        let h = hash_password("SmokeTest9!");
        assert!(check_password("SmokeTest9!", &h));
        assert!(!check_password("wrong", &h));
    }
}
