// SPDX-License-Identifier: GPL-3.0-only
//! Numeric local diagnostics only: no packets, peer names, addresses or secrets.
use openrad::runtime::{PeerState, Snapshot};
use serde_json::{json, Value};
use std::{fs, io::{BufWriter, Write}, os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::Path, sync::mpsc::{self, SyncSender}, thread, time::{Instant, SystemTime, UNIX_EPOCH}};

pub struct PerformanceLog { sender: Option<SyncSender<Value>>, writer: Option<thread::JoinHandle<()>>, next: Instant }
impl PerformanceLog {
    pub fn open(profile: &Path) -> std::io::Result<Self> {
        let directory = profile.join("performance");
        fs::DirBuilder::new().recursive(true).mode(0o700).create(&directory)?;
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
        let file = fs::OpenOptions::new().create_new(true).write(true).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW).open(directory.join(format!("metrics-{stamp}-{}.jsonl",std::process::id())))?;
        let setup_file = fs::OpenOptions::new().create_new(true).write(true).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW).open(directory.join(format!("setup-{stamp}-{}.jsonl",std::process::id())))?;
        let (sender, receiver) = mpsc::sync_channel::<Value>(64);
        let writer = thread::spawn(move || {
            let mut output = BufWriter::new(file);
            let mut setup_output = BufWriter::new(setup_file);
            let mut bytes = 0;
            let mut setup_bytes = 0;
            for value in receiver {
                if value.get("event").is_some() {
                    if let Some(record) = setup_record(&value) {
                        if let Ok(mut line) = serde_json::to_vec(&record) {
                            line.push(b'\n');
                            if setup_bytes + line.len() <= 8 * 1024 * 1024 && setup_output.write_all(&line).is_ok() {
                                setup_bytes += line.len();
                                let _ = setup_output.flush();
                            }
                        }
                    }
                    continue;
                }
                let Ok(mut line) = serde_json::to_vec(&value) else { continue };
                line.push(b'\n');
                // Stop recording at 8 MiB; retain earlier journals without deletion.
                if bytes + line.len() > 8 * 1024 * 1024 { break; }
                if output.write_all(&line).is_err() || output.flush().is_err() { break; }
                bytes += line.len();
            }
        });
        Ok(Self {sender:Some(sender),writer:Some(writer),next:Instant::now()})
    }
    pub fn diagnostics(&self) -> openrad::diagnostics::Diagnostics {
        self.sender.as_ref().map(|sender| openrad::diagnostics::Diagnostics::to_channel(sender.clone())).unwrap_or_default()
    }
    pub fn record(&mut self, state: &Snapshot) {
        if Instant::now() < self.next { return; }
        self.next = Instant::now() + std::time::Duration::from_secs(1);
        let unix_ms = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis();
        let connected: Vec<_> = state.peers.values().filter(|p| p.status == PeerState::Connected).collect();
        let value = json!({"unix_ms":unix_ms,"elapsed_seconds":state.elapsed_secs,"traffic":state.traffic,
            "peer_frame_queue_capacity":openrad::runtime::PEER_FRAME_QUEUE,
            "connected_peers":connected.len(),"direct_udp":connected.iter().filter(|p| p.transport == Some(openrad::peer::TransportPath::DirectUdp)).count(),
            "relay":connected.iter().filter(|p| p.transport == Some(openrad::peer::TransportPath::Relay)).count(),
            "interface_ready":state.interface_ready,"interface_error":state.interface_error.is_some()});
        if let Some(sender) = &self.sender { let _ = sender.try_send(value); }
    }
}

/// Explicit allowlists: raw errors, endpoint addresses, tickets, keys and packet
/// contents never reach the setup journal, even if upstream adds more fields.
fn setup_record(value: &Value) -> Option<Value> {
    let event = value.get("event")?.as_str()?;
    if !matches!(event, "session_start" | "session_attached" | "interface_ready" | "peer_connecting" | "peer_transport_attempts" | "peer_connected" | "peer_closed" | "peer_retry_scheduled") { return None; }
    let details = value.get("details")?;
    let mut record = json!({"event":event,"unix_ms":value.get("timestamp_ms")?.as_u64()?});
    for name in ["rid", "attempt", "setup_ms", "lifetime_ms", "connected_ms", "delay_ms", "latency_ms", "peers", "networks"] {
        if let Some(number) = details.get(name).and_then(Value::as_u64) { record[name] = number.into(); }
    }
    for name in ["incoming", "cancelled"] {
        if let Some(flag) = details.get(name).and_then(Value::as_bool) { record[name] = flag.into(); }
    }
    let transport = &details["transport"];
    if event == "peer_transport_attempts" {
        for name in ["tcp_candidates", "udp_candidates", "mapped_udp_candidates"] {
            record[name] = transport.get(name).and_then(Value::as_array).map_or(0, Vec::len).into();
        }
        record["attempts"] = transport.get("attempts").and_then(Value::as_array).map(|attempts| attempts.iter().take(128).map(|attempt| {
            let mut item = json!({"failed":attempt.get("error").is_some()});
            let phase = attempt.get("phase").and_then(Value::as_str).unwrap_or("");
            if matches!(phase, "coordinator_authenticated" | "coordinator_record" | "direct_tcp_start" | "direct-tcp-0" | "direct-tcp-1" | "direct-tcp-2" | "direct-tcp-3" | "direct-udp" | "mapped-udp" | "relay" | "relay_preparation" | "ues_mapping" | "udp_bind" | "candidate_exclusion" | "candidate_validation" | "mapped_candidate_validation") { item["phase"] = phase.into(); }
            for name in ["setup_ms", "elapsed_ms", "operation", "candidates", "lanes"] {
                if let Some(number) = attempt.get(name).and_then(Value::as_u64) { item[name] = number.into(); }
            }
            item
        }).collect::<Vec<_>>()).unwrap_or_default().into();
    } else if let Some(path) = transport.as_str().filter(|p| matches!(*p, "DirectTcp" | "DirectUdp" | "Relay")) {
        record["transport"] = path.into();
    }
    Some(record)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn setup_journal_keeps_timing_but_never_copies_sensitive_extra_fields() {
        let value = json!({"event":"peer_transport_attempts","timestamp_ms":123,"details":{
            "rid":42,"attempt":1,"password":"synthetic-secret","transport":{
                "endpoint":"192.0.2.3:1234","tcp_candidates":[{"endpoint":"192.0.2.3:1"}],
                "attempts":[{"phase":"coordinator_authenticated","setup_ms":250,"error":"synthetic-secret"},
                    {"phase":"synthetic-secret","setup_ms":5,"ticket":"synthetic-secret"}]}}});
        let clean = setup_record(&value).unwrap();
        assert_eq!(clean["tcp_candidates"],1);
        assert_eq!(clean["attempts"][0]["setup_ms"],250);
        assert_eq!(clean["attempts"][0]["failed"],true);
        let text = clean.to_string();
        assert!(!text.contains("synthetic-secret") && !text.contains("192.0.2.3"));
    }
    #[test]
    fn session_event_is_kept_without_logging_server_address() {
        let value = json!({"event":"session_attached","timestamp_ms":123,"details":{"peers":2,"server":"synthetic-secret"}});
        assert_eq!(setup_record(&value).unwrap()["peers"],2);
        assert!(setup_record(&json!({"event":"unlisted","details":{}})).is_none());
    }
}
impl Drop for PerformanceLog {
    fn drop(&mut self) { self.sender.take(); if let Some(writer)=self.writer.take() { let _=writer.join(); } }
}
