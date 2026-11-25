//! EngVPN Merlin panel daemon — static musl-friendly binary (no Node/V8).
#![recursion_limit = "256"]
mod account;
mod api;
mod auth;
mod diag;
mod engines;
mod paths;
mod shell;
mod state;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(name = "engvpn-daemon", version, about = "EngVPN Merlin panel (Rust)")]
struct Cli {
    #[arg(long, env = "ENGVPN_DATA_DIR", global = true)]
    data_dir: Option<PathBuf>,

    #[arg(long, env = "ENGVPN_PORT", default_value_t = 8790, global = true)]
    port: u16,

    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Start the panel HTTP server (foreground)
    Serve,
    /// Read panel password from stdin; store pbkdf2 hash in data/state.json
    SetPassword,
    /// Print package version
    Version,
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .with_target(false)
        .try_init();

    let cli = Cli::parse();
    let paths = paths::Paths::resolve(cli.data_dir.clone())?;

    match cli.cmd {
        Commands::Version => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Commands::SetPassword => {
            auth::set_password_from_stdin(&paths).context("set-password")?;
            println!("panel password saved");
            Ok(())
        }
        Commands::Serve => {
            // Ignore SIGHUP (curl|sh / SSH parent death) — Merlin parity with Node panel.
            #[cfg(unix)]
            {
                use tokio::signal::unix::{signal, SignalKind};
                let mut sighup = signal(SignalKind::hangup())?;
                tokio::spawn(async move {
                    loop {
                        sighup.recv().await;
                    }
                });
            }
            if let Ok(pidfile) = std::env::var("ENGVPN_PID_FILE") {
                let _ = std::fs::write(&pidfile, format!("{}\n", std::process::id()));
            }
            api::serve(paths, cli.port).await
        }
    }
}
