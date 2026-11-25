use anyhow::{bail, Context, Result};
use std::env;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Paths {
    pub prefix: PathBuf,
    pub share: PathBuf,
    pub data: PathBuf,
    pub www: PathBuf,
    pub version_file: PathBuf,
    pub engvpnd: PathBuf,
}

impl Paths {
    pub fn resolve(data_dir: Option<PathBuf>) -> Result<Self> {
        let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("engvpn-daemon"));
        let exe_dir = exe
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));

        // Layout: $PREFIX/sbin/engvpn-daemon → $PREFIX/share/engvpn
        let prefix = if exe_dir.ends_with("sbin") {
            exe_dir.parent().unwrap_or(exe_dir.as_path()).to_path_buf()
        } else {
            // Dev / cargo run: prefer ENGVPN_PREFIX or walk up from CARGO_MANIFEST_DIR
            if let Ok(p) = env::var("ENGVPN_PREFIX") {
                PathBuf::from(p)
            } else {
                // crates/engvpn-daemon → engvpn/
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .parent()
                    .and_then(|p| p.parent())
                    .map(|p| p.to_path_buf())
                    .unwrap_or_else(|| PathBuf::from("."))
            }
        };

        let share = prefix.join("share/engvpn");
        let data = data_dir
            .or_else(|| env::var_os("ENGVPN_DATA_DIR").map(PathBuf::from))
            .unwrap_or_else(|| prefix.join("data"));

        let www_candidates = [
            share.join("www"),
            share.join("runtime/public"),
            prefix.join("www"),
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .and_then(|p| p.parent())
                .map(|p| p.join("www"))
                .unwrap_or_else(|| PathBuf::from("www")),
        ];
        let www = www_candidates
            .into_iter()
            .find(|p| p.join("index.html").is_file())
            .unwrap_or_else(|| share.join("www"));

        let version_file = if share.join("VERSION").is_file() {
            share.join("VERSION")
        } else {
            prefix.join("VERSION")
        };

        let engvpnd = prefix.join("sbin/engvpnd");

        std::fs::create_dir_all(&data).with_context(|| format!("mkdir {}", data.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o700));
        }

        Ok(Self {
            prefix,
            share,
            data,
            www,
            version_file,
            engvpnd,
        })
    }

    pub fn installed_version(&self) -> String {
        std::fs::read_to_string(&self.version_file)
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string())
    }

    pub fn state_path(&self) -> PathBuf {
        self.data.join("state.json")
    }

    pub fn open_panel(&self) -> bool {
        env::var("ENGVPN_OPEN_PANEL").ok().as_deref() == Some("1")
            || self.data.join("open-panel").is_file()
    }

    pub fn ensure_writable_data(&self) -> Result<()> {
        if !self.data.is_dir() {
            bail!("data dir missing: {}", self.data.display());
        }
        Ok(())
    }
}
