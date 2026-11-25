//! Diagnostics: /proc sampling without Node/V8 — safe on Merlin low-RAM.
use serde_json::{json, Value};
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Default)]
pub struct LoadCache {
    last: Option<(Instant, Value)>,
    prev_cpu: Option<(u64, u64)>,
}

impl LoadCache {
    pub fn system_load(&mut self, data_dir: &Path, panel_started: Instant) -> Value {
        if let Some((at, ref v)) = self.last {
            if at.elapsed() < Duration::from_secs(2) {
                return v.clone();
            }
        }
        let (cpu, ram_used, ram_total) = read_load(&mut self.prev_cpu);
        let panel_uptime = panel_started.elapsed().as_millis() as u64;
        let uptime = addon_uptime_ms(data_dir, panel_uptime);
        let proc_rss = read_self_rss();
        let v = json!({
            "ok": true,
            "cpu": cpu,
            "ramUsed": ram_used,
            "ramTotal": ram_total,
            "proc": proc_rss,
            "uptime": uptime,
            "panelUptime": panel_uptime,
            "processes": top_processes(64, 16),
        });
        self.last = Some((Instant::now(), v.clone()));
        v
    }
}

pub fn addon_uptime_ms(data_dir: &Path, panel_uptime_ms: u64) -> u64 {
    let marker = data_dir.join(".addon-uptime-since");
    if let Ok(s) = fs::read_to_string(&marker) {
        if let Ok(sec) = s.trim().parse::<u64>() {
            if sec > 1_000_000_000 {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(sec);
                return now.saturating_sub(sec) * 1000;
            }
        }
    }
    // Seed marker so panel restarts keep session clock
    let since = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
        .saturating_sub(panel_uptime_ms / 1000);
    if since > 0 {
        let _ = fs::create_dir_all(data_dir);
        let _ = fs::write(&marker, format!("{since}\n"));
    }
    panel_uptime_ms
}

fn read_load(prev: &mut Option<(u64, u64)>) -> (f64, u64, u64) {
    let (idle, total) = read_cpu_times();
    let cpu = if let Some((pi, pt)) = *prev {
        let di = idle.saturating_sub(pi) as f64;
        let dt = total.saturating_sub(pt) as f64;
        if dt > 0.0 {
            ((1.0 - di / dt) * 100.0).clamp(0.0, 100.0)
        } else {
            0.0
        }
    } else {
        0.0
    };
    *prev = Some((idle, total));
    let (ram_total, ram_avail) = read_mem();
    let ram_used = ram_total.saturating_sub(ram_avail);
    (cpu, ram_used, ram_total)
}

fn read_cpu_times() -> (u64, u64) {
    let Ok(s) = fs::read_to_string("/proc/stat") else {
        return (0, 0);
    };
    let line = s.lines().next().unwrap_or("");
    let mut parts = line.split_whitespace().skip(1);
    let mut nums = [0u64; 8];
    for n in nums.iter_mut() {
        *n = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    }
    let idle = nums[3] + nums[4];
    let total: u64 = nums.iter().sum();
    (idle, total)
}

fn read_mem() -> (u64, u64) {
    let Ok(s) = fs::read_to_string("/proc/meminfo") else {
        return (0, 0);
    };
    let mut total = 0u64;
    let mut avail = 0u64;
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            total = rest.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0) * 1024;
        } else if let Some(rest) = line.strip_prefix("MemAvailable:") {
            avail = rest.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0) * 1024;
        }
    }
    (total, avail)
}

fn read_self_rss() -> u64 {
    let Ok(s) = fs::read_to_string("/proc/self/status") else {
        return 0;
    };
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            let kb: u64 = rest.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0);
            return kb * 1024;
        }
    }
    0
}

fn top_processes(max_scan: usize, top_n: usize) -> Value {
    let Ok(rd) = fs::read_dir("/proc") else {
        return json!([]);
    };
    let mut rows: Vec<(u64, u64, String, String)> = Vec::new(); // rss, pid, name, cmd
    let mut scanned = 0usize;
    for entry in rd.flatten() {
        if scanned >= max_scan {
            break;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        scanned += 1;
        let pid: u64 = name.parse().unwrap_or(0);
        let status = fs::read_to_string(entry.path().join("status")).unwrap_or_default();
        let mut rss = 0u64;
        let mut comm = String::new();
        for line in status.lines() {
            if let Some(rest) = line.strip_prefix("VmRSS:") {
                rss = rest.split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0) * 1024;
            } else if let Some(rest) = line.strip_prefix("Name:") {
                comm = rest.trim().to_string();
            }
        }
        rows.push((rss, pid, comm, String::new()));
    }
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    rows.truncate(top_n);
    // cmdline only for top-N
    for row in rows.iter_mut() {
        let cmd = fs::read(format!("/proc/{}/cmdline", row.1))
            .ok()
            .map(|b| {
                String::from_utf8_lossy(&b)
                    .split('\0')
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default();
        row.3 = if cmd.is_empty() { row.2.clone() } else { cmd };
    }
    Value::Array(
        rows.into_iter()
            .map(|(rss, pid, name, cmd)| {
                json!({
                    "pid": pid,
                    "name": name,
                    "cmd": cmd.chars().take(120).collect::<String>(),
                    "rss": rss,
                    "engvpn": cmd.contains("engvpn") || name.contains("engvpn"),
                })
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn load_does_not_panic() {
        let mut cache = LoadCache::default();
        let dir = tempdir().unwrap();
        let v = cache.system_load(dir.path(), Instant::now());
        assert_eq!(v["ok"], true);
        assert!(v["panelUptime"].as_u64().unwrap() < 60_000);
    }
}
