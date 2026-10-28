// SPDX-License-Identifier: GPL-3.0-only
//! Keychain access through a small signed component kept stable across rebuilds.
use anyhow::{bail, ensure, Context, Result};
use std::{io::{Read, Write}, path::Path, process::{Command, Stdio},
    sync::{atomic::{AtomicBool, Ordering}, Arc}, thread, time::{Duration, Instant}};
use zeroize::Zeroizing;

const LIMIT: u64 = 65_536;

fn invoke(operation: &str, profile: &Path, payload: Option<&[u8]>, stop: &AtomicBool) -> Result<Option<Zeroizing<Vec<u8>>>> {
    let helper = std::env::current_exe()?.with_file_name("radmin-identity-helper");
    let mut child = Command::new(helper).arg(operation).arg(profile)
        .stdin(if payload.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
        .context("Cannot start the Keychain identity component")?;
    let output = child.stdout.take().context("Missing identity pipe")?;
    let reader = thread::spawn(move || {
        let mut bytes = Zeroizing::new(Vec::new());
        output.take(LIMIT + 1).read_to_end(&mut bytes).map(|_| bytes)
    });
    if let Some(bytes) = payload {
        let written = child.stdin.take().context("Missing identity input pipe")?.write_all(bytes);
        if written.is_err() { let _ = child.kill(); let _ = child.wait(); let _ = reader.join(); bail!("Keychain storage pipe failed"); }
    }
    let deadline = Instant::now() + Duration::from_secs(if operation == "migrate" { 120 } else { 15 });
    let status = loop {
        if stop.load(Ordering::Relaxed) || Instant::now() >= deadline {
            let _ = child.kill(); let _ = child.wait(); let _ = reader.join();
            bail!("Keychain access cancelled or timed out");
        }
        if let Some(status) = child.try_wait()? { break status; }
        thread::sleep(Duration::from_millis(30));
    };
    let bytes = reader.join().map_err(|_| anyhow::anyhow!("Keychain output reader failed"))??;
    ensure!(bytes.len() as u64 <= LIMIT, "Keychain identity size limit");
    match status.code() {
        Some(0) => Ok(Some(bytes)),
        Some(10) => Ok(None),
        Some(12) => bail!("Keychain identity component rejected the caller signature"),
        _ => bail!("Keychain identity access was not authorized; previous device preserved"),
    }
}

pub fn read(profile: &Path, stop: &AtomicBool) -> Result<Option<Zeroizing<Vec<u8>>>> {
    invoke("read", profile, None, stop)
}
pub fn load_or_migrate(profile: &Path, stop: &Arc<AtomicBool>) -> Result<Option<Zeroizing<Vec<u8>>>> {
    match read(profile, stop)? {
        Some(bytes) => Ok(Some(bytes)),
        None => invoke("migrate", profile, None, stop),
    }
}
pub fn store(profile: &Path, bytes: &[u8], stop: &AtomicBool) -> Result<()> {
    ensure!(!bytes.is_empty() && bytes.len() as u64 <= LIMIT, "Invalid identity size");
    ensure!(invoke("store", profile, Some(bytes), stop)?.is_some(), "Keychain storage failed");
    Ok(())
}
