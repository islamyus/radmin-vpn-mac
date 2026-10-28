// SPDX-License-Identifier: GPL-3.0-only
//! Private stdio frontend for the canonical OpenRad runtime. No secrets in argv.
use anyhow::{bail, ensure, Context, Result};
use openrad::{network::{NetworkPassword, NetworkRequest}, output::ReportDirectory,
    protocol::Identity, runtime::{self, Command, Options, Update}, session::Session};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{fs::{self, OpenOptions}, io::{self, BufRead, Read, Write},
    os::{fd::AsRawFd, unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt}},
    path::{Path, PathBuf}, sync::{atomic::{AtomicBool, Ordering}, mpsc, Arc},
    thread::{self, JoinHandle}, time::Duration};
use zeroize::Zeroizing;
mod performance;
mod session_identity;
mod identity_store;

const MAX_COMMAND: u64 = 16_384;

#[derive(Deserialize)]
struct Request {
    id: u64,
    command: String,
    #[serde(default)] name: String,
    #[serde(default)] password: Option<NetworkPassword>,
    #[serde(default)] peer: u64,
    #[serde(default)] control_only: bool,
    #[serde(default)] force_relay: bool,
}

fn emit(value: Value) {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let _ = serde_json::to_writer(&mut out, &value);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}
fn phase(value: &str, detail: &str) { emit(json!({"event":"phase", "phase":value, "detail":detail})); }
fn reply(id: u64, result: Result<()>) {
    match result {
        Ok(()) => emit(json!({"event":"reply","id":id,"ok":true})),
        Err(e) => emit(json!({"event":"reply","id":id,"ok":false,"error":format!("{e:#}")})),
    }
}
fn report(update: Update) {
    let event = match update {
        Update::State(snapshot) => json!({"event":"state", "snapshot":snapshot}),
        Update::Operation {message,error} => json!({"event":"operation","message":message,"error":error}),
        Update::CommandResult {id,message,error,catalog} => json!({"event":"result","id":id,"message":message,"error":error,"catalog":catalog}),
        Update::Catalog {query,networks,cursor,append} => json!({"event":"catalog","query":query,"networks":networks,"cursor":cursor,"append":append}),
        Update::Ping {peer,id,rtt_ms,error} => json!({"event":"ping","peer":peer,"id":id,"rtt_ms":rtt_ms,"error":error}),
    };
    emit(event);
}

fn identity(profile: &Path, name: &str, stop: Arc<AtomicBool>) -> Result<Identity> {
    match identity_store::load_or_migrate(profile, &stop)? {
        Some(bytes) => return Identity::from_secret(&bytes),
        None => (), // Both the current item and legacy item are absent.
    }
    let intent = profile.join("registration-pending");
    ensure!(!intent.exists(), "An earlier registration has an unknown outcome. The previous device was preserved; automatic registration is disabled.");
    ensure!(!profile.join("registration-complete").exists(),
        "Saved Keychain identity is missing for a previously registered device; automatic registration is disabled");
    phase("provisioning", "Регистрация устройства в Radmin");
    let new_identity = Session::provision_controlled(openrad::SERVER_MODULUS, name,
        openrad::DEFAULT_BOOTSTRAP_HOST, &ReportDirectory::disabled(),
        &mut || {
            // Mark only the first registering login, including authenticated redirects.
            if !intent.exists() {
                let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&intent)?;
                file.write_all(b"Registration may have reached the service. Do not retry blindly.\n")?;
                file.sync_all()?;
            }
            Ok(())
        }, Some(stop.clone()), &mut |_| {})?;
    let bytes = Zeroizing::new(serde_json::to_vec(&new_identity)?);
    // Retain the issued identity in this worker and retry storage, never registration.
    loop {
        match identity_store::store(profile, &bytes, &stop) {
            Ok(()) => break,
            Err(_) => {
                phase("storage", "Не удалось сохранить устройство в Связке ключей. Разблокируйте её; запись будет повторена.");
                if stop.load(Ordering::Relaxed) {
                    // Preserve recovery under private permissions instead of losing an issued device.
                    let mut recovery = OpenOptions::new().write(true).create_new(true).mode(0o600)
                        .open(profile.join("identity-recovery.json"))?;
                    recovery.write_all(&bytes)?;
                    recovery.sync_all()?;
                    bail!("Identity saved in private recovery file after Keychain storage failure");
                }
                thread::sleep(Duration::from_secs(3));
            }
        }
    }
    fs::rename(intent, profile.join("registration-complete"))?;
    Ok(new_identity)
}

struct Running { stop: Arc<AtomicBool>, commands: mpsc::SyncSender<Command>, worker: JoinHandle<()> }
impl Running {
    fn stop(self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = self.worker.join();
    }
}

/// Manual cold-process check: read only this identity, forbid every Keychain UI,
/// never provision a device or start a network/interface, never output secrets.
fn check_identity_access(profile: &Path) -> Result<()> {
    let profile = profile.canonicalize()?;
    let bytes = identity_store::read(&profile, &AtomicBool::new(false))?
        .context("Saved identity has not yet been migrated to the stable Keychain component")?;
    let _device = Identity::from_secret(&bytes)?;
    println!("Saved identity access OK; user interaction disabled");
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() == 4 && args[1] == "--check-identity-access" && args[2] == "--profile" {
        return check_identity_access(Path::new(&args[3]));
    }
    ensure!(args.len() == 4 && args[1] == "--stdio" && args[2] == "--profile",
        "Usage: radmin-mac-engine --stdio --profile PATH");
    let profile = PathBuf::from(&args[3]);
    if !profile.exists() { fs::DirBuilder::new().recursive(true).mode(0o700).create(&profile)?; }
    ensure!(fs::symlink_metadata(&profile)?.is_dir(), "profile must be a directory");
    fs::set_permissions(&profile, fs::Permissions::from_mode(0o700))?;
    let profile = profile.canonicalize()?;
    let lock = OpenOptions::new().read(true).write(true).create(true).truncate(false)
        .mode(0o600).custom_flags(libc::O_NOFOLLOW).open(profile.join("engine.lock"))?;
    ensure!(unsafe { libc::flock(lock.as_raw_fd(),libc::LOCK_EX|libc::LOCK_NB) } == 0,
        "This profile already has an active engine");
    let run_dir = profile.parent().context("profile has no parent")?.join("run");
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&run_dir)?;
    // Only our adapter reads this; inherited by its short-lived authorization launcher.
    std::env::set_var("RADMIN_RUN_DIR", &run_dir);
    let alive = Arc::new(AtomicBool::new(true));
    let session_identity = Arc::new(session_identity::SessionIdentity::<Identity>::new());
    let mut running: Option<Running> = None;
    emit(json!({"event":"ready","version":env!("CARGO_PKG_VERSION"),"engine":"OpenRad 2.0.1","native":true}));
    let mut stdin = io::stdin().lock();
    loop {
        let mut line = Zeroizing::new(Vec::new());
        let count = (&mut stdin).take(MAX_COMMAND+1).read_until(b'\n', &mut line)?;
        if count == 0 { break; }
        if line.len() as u64 > MAX_COMMAND { bail!("local command exceeds limit"); }
        let request: Request = match serde_json::from_slice(&line) {
            Ok(r) => r,
            Err(_) => { emit(json!({"event":"error","message":"Invalid local command"})); continue; }
        };
        if running.as_ref().is_some_and(|r| r.worker.is_finished()) { running.take().unwrap().stop(); }
        let result = (|| -> Result<()> {
            match request.command.as_str() {
                "connect" => {
                    ensure!(running.is_none(), "Already connecting or connected");
                    openrad::protocol::validate_node_name(&request.name)?;
                    let stop = Arc::new(AtomicBool::new(false));
                    let worker_stop = stop.clone();
                    let (tx,rx) = mpsc::sync_channel(128);
                    let profile = profile.clone();
                    let alive = alive.clone();
                    let session_identity = session_identity.clone();
                    let worker = thread::spawn(move || {
                        let result = (|| -> Result<()> {
                            let device = session_identity.get_or_load(|| identity(&profile, &request.name, worker_stop.clone()))?;
                            ensure!(!worker_stop.load(Ordering::Relaxed), "cancelled");
                            emit(json!({"event":"device","name":device.node_name,"vip":device.vip}));
                            phase("connecting", "Подключение к серверу Radmin");
                            let helper = std::env::current_exe()?.with_file_name("radmin-bridge");
                            let metrics = std::sync::Mutex::new(performance::PerformanceLog::open(&profile).ok());
                            let diagnostics = metrics.lock().ok().and_then(|log| log.as_ref().map(|log| log.diagnostics())).unwrap_or_default();
                            let options = Options { helper:Some(helper), disable_interface:request.control_only,
                                force_relay:request.force_relay, diagnostics, ..Default::default() };
                            runtime::run(device, openrad::SERVER_MODULUS.to_vec(), options, rx, worker_stop.clone(), |update| {
                                if let Update::State(state) = &update { if let Ok(mut logger) = metrics.lock() { if let Some(log) = logger.as_mut() { log.record(state); } } }
                                report(update);
                            })
                        })();
                        if alive.load(Ordering::Relaxed) {
                            match result {
                                Err(e) if !worker_stop.load(Ordering::Relaxed) => phase("error", &format!("{e:#}")),
                                _ => phase("stopped", "Отключено"),
                            }
                        }
                    });
                    running = Some(Running {stop,commands:tx,worker});
                },
                "disconnect" => {
                    phase("stopping", "Отключение");
                    if let Some(worker) = running.take() { worker.stop(); }
                    phase("stopped", "Отключено");
                },
                "join" | "create" | "leave" | "retry_interface" | "retry_peers" | "ping" | "search" => {
                    let current = running.as_ref().context("Connect first")?;
                    let command = match request.command.as_str() {
                        "join" => Command::Network(NetworkRequest::Join {name:request.name,password:request.password}),
                        "create" => Command::Network(NetworkRequest::Create {name:request.name,password:request.password.context("Network password is required")?}),
                        "leave" => Command::Leave(request.name),
                        "retry_interface" => Command::RetryInterface,
                        "retry_peers" => Command::RetryPeers,
                        "ping" => Command::Ping {peer:request.peer},
                        _ => Command::Search {query:request.name,cursor:0},
                    };
                    current.commands.try_send(Command::Tagged {id:request.id,command:Box::new(command)})
                        .context("Engine command queue is full or closed")?;
                },
                _ => bail!("Unknown command"),
            }
            Ok(())
        })();
        reply(request.id,result);
    }
    alive.store(false, Ordering::Relaxed);
    if let Some(worker) = running { worker.stop(); }
    Ok(())
}
