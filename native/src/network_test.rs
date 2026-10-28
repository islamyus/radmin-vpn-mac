// SPDX-License-Identifier: GPL-3.0-only
//! Standalone test of two owned endpoints; never changes network settings.
use anyhow::{bail, ensure, Context, Result};
use rand::RngCore;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use socket2::{Domain, Protocol, Socket, Type};
use std::{fs, io::{self, Read, Write}, net::{Ipv4Addr, SocketAddr, TcpStream, UdpSocket},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt}, path::{Path, PathBuf}, process::Command,
    sync::{atomic::{AtomicBool, Ordering}, Arc}, thread, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};

const MAGIC: &[u8;8] = b"RVMAC001";
struct Options { source:Ipv4Addr, peer:Ipv4Addr, port:u16, mib:u32, rounds:u32, output:PathBuf, label:String, loopback:bool }
fn prompt(label:&str, default:&str)->Result<String> {
    if default.is_empty() { print!("{label}: "); } else { print!("{label} [{default}]: "); }
    io::stdout().flush()?;
    let mut value=String::new(); io::stdin().read_line(&mut value)?;
    Ok(if value.trim().is_empty() {default.to_owned()} else {value.trim().to_owned()})
}
fn local_vip()->Option<String> {
    let output=Command::new("/sbin/ifconfig").output().ok()?;
    String::from_utf8_lossy(&output.stdout).lines().find_map(|line| {
        let mut parts=line.split_whitespace();
        if parts.next()!=Some("inet") {return None;}
        let address=parts.next()?;
        address.parse::<Ipv4Addr>().ok().filter(|ip|ip.octets()[0]==26).map(|_|address.to_owned())
    })
}
fn options()->Result<Options> {
    let mut fields=std::collections::HashMap::new();
    let mut args=std::env::args().skip(1);
    while let Some(key)=args.next() {
        if key=="--interactive" || key=="--allow-loopback" {fields.insert(key,"true".to_owned());continue;}
        ensure!(["--source","--peer","--port","--mib","--rounds","--output","--label"].contains(&key.as_str()),"Unknown option {key}");
        fields.insert(key,args.next().context("Option needs a value")?);
    }
    if fields.contains_key("--interactive") {
        println!("\nПроверка Radmin: сначала запустите Start-Windows-Test.cmd на Windows.\nОставьте обычный VPN включённым на обеих машинах. Пароли не нужны.\n");
        fields.insert("--source".into(),prompt("Radmin IP этого Mac",&local_vip().unwrap_or_default())?);
        fields.insert("--peer".into(),prompt("Radmin IP Windows","")?);
        fields.insert("--label".into(),prompt("Название условий теста","VPN включён на обеих машинах")?);
    }
    let source:Ipv4Addr=fields.get("--source").context("Use --source RADMIN_IP --peer WINDOWS_IP, or --interactive")?.parse()?;
    let peer:Ipv4Addr=fields.get("--peer").context("Missing --peer")?.parse()?;
    let loopback=fields.contains_key("--allow-loopback");
    for ip in [source,peer] {ensure!(ip.octets()[0]==26 || (loopback && ip.is_loopback()),"Use Radmin IPv4 addresses from 26.0.0.0/8");}
    let stamp=SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis();
    let o=Options {source,peer,port:fields.get("--port").map_or(Ok(48671),|v|v.parse())?,
        mib:fields.get("--mib").map_or(Ok(4),|v|v.parse())?,rounds:fields.get("--rounds").map_or(Ok(2),|v|v.parse())?,
        output:fields.get("--output").map(PathBuf::from).unwrap_or_else(||PathBuf::from(format!("Reports/test-{stamp}-{}",std::process::id()))),
        label:fields.remove("--label").unwrap_or_else(||"Условия не указаны".into()),loopback};
    ensure!(o.port>0 && (1..=64).contains(&o.mib) && (1..=5).contains(&o.rounds),"Invalid port / MiB (1..64) / rounds (1..5)");
    ensure!(!o.output.exists(),"Output directory already exists; choose a new directory");
    Ok(o)
}
fn summary(rtts:&mut [f64], sent:usize, errors:std::collections::BTreeMap<String,usize>)->Value {
    rtts.sort_by(f64::total_cmp);
    let percentile=|p:f64| if rtts.is_empty(){Value::Null}else{json!(rtts[((rtts.len()-1) as f64*p).round() as usize])};
    json!({"sent":sent,"received":rtts.len(),"loss_percent":if sent==0{0.0}else{100.0*(sent-rtts.len()) as f64/sent as f64},
        "median_ms":percentile(0.5),"p95_ms":percentile(0.95),"max_ms":rtts.last(),"errors":errors})
}
fn udp(source:Ipv4Addr,peer:Ipv4Addr,port:u16,count:Option<usize>,stop:Arc<AtomicBool>,until:Instant,mut ready:Option<std::sync::mpsc::SyncSender<()>>)->Value {
    let run=(||->Result<Value>{
        let socket=UdpSocket::bind((source,0))?; socket.connect((peer,port))?;
        let mut rtts=Vec::new(); let mut errors=std::collections::BTreeMap::new(); let mut sent=0;
        while count.is_none_or(|n|sent<n) && !stop.load(Ordering::Relaxed) && Instant::now()<until {
            let mut packet=vec![0;1200]; rand::thread_rng().fill_bytes(&mut packet); packet[..8].copy_from_slice(MAGIC);
            let started=Instant::now(); sent+=1;
            if let Some(signal)=ready.take(){let _=signal.send(());}
            let result=(||->io::Result<()> {
                socket.send(&packet)?;
                let deadline=until.min(started+Duration::from_millis(1500)); let mut bytes=[0;1400];
                loop {
                    let remaining=deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero(){return Err(io::ErrorKind::TimedOut.into());}
                    socket.set_read_timeout(Some(remaining))?;
                    let n=socket.recv(&mut bytes)?;
                    if bytes[..n]==packet {return Ok(());}
                }
            })();
            match result {Ok(())=>rtts.push(started.elapsed().as_secs_f64()*1000.0),Err(e)=>*errors.entry(format!("{:?}",e.kind())).or_default()+=1}
            thread::sleep(Duration::from_millis(200));
        }
        Ok(summary(&mut rtts,sent,errors))
    })();
    run.unwrap_or_else(|e|json!({"error":format!("{e:#}")}))
}
fn bounded_read(stream:&mut TcpStream, bytes:&mut [u8], deadline:Instant)->Result<()> {
    let mut offset=0;
    while offset<bytes.len() {
        ensure!(Instant::now()<deadline,"Transfer deadline exceeded after {offset} bytes in current block");
        stream.set_read_timeout(Some(deadline.saturating_duration_since(Instant::now()).min(Duration::from_secs(3))))?;
        match stream.read(&mut bytes[offset..]) {Ok(0)=>bail!("Server closed the connection"),Ok(n)=>offset+=n,
            Err(e) if matches!(e.kind(),io::ErrorKind::Interrupted|io::ErrorKind::WouldBlock|io::ErrorKind::TimedOut)=>(),Err(e)=>return Err(e).context("TCP receive (server/VPN may be unavailable)")}
    }
    Ok(())
}
fn bounded_write(stream:&mut TcpStream,bytes:&[u8],deadline:Instant)->Result<()> {
    let mut offset=0;
    while offset<bytes.len() {
        ensure!(Instant::now()<deadline,"Transfer deadline exceeded while sending a block");
        stream.set_write_timeout(Some(deadline.saturating_duration_since(Instant::now()).min(Duration::from_secs(3))))?;
        match stream.write(&bytes[offset..]) {Ok(0)=>bail!("Server stopped accepting data"),Ok(n)=>offset+=n,
            Err(e) if matches!(e.kind(),io::ErrorKind::Interrupted|io::ErrorKind::WouldBlock|io::ErrorKind::TimedOut)=>(),Err(e)=>return Err(e).context("TCP send")}
    }
    Ok(())
}
fn transfer(o:&Options,mode:u8,until:Instant)->Result<Value> {
    let socket=Socket::new(Domain::IPV4,Type::STREAM,Some(Protocol::TCP))?;
    socket.bind(&SocketAddr::from((o.source,0)).into()).context("Radmin IP is absent on this Mac")?;
    socket.connect_timeout(&SocketAddr::from((o.peer,o.port)).into(),Duration::from_secs(5)).context("Cannot connect to test server; check Ready, the VPN route and firewall")?;
    let mut stream:TcpStream=socket.into(); stream.set_nodelay(true)?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let size=o.mib*1024*1024;
    let mut header=MAGIC.to_vec(); header.push(mode); header.extend(size.to_be_bytes()); stream.write_all(&header)?;
    let started=Instant::now(); let deadline=until.min(started+Duration::from_secs(180));
    let mut sha=Sha256::new(); let mut done=0u32; let mut bytes=vec![0;65536]; let mut progress=Instant::now();
    while done<size {
        ensure!(Instant::now()<deadline,"Transfer deadline exceeded at {done}/{size} bytes");
        let n=bytes.len().min((size-done) as usize); let block=&mut bytes[..n];
        if mode==b'U' {
            rand::thread_rng().fill_bytes(block);
            bounded_write(&mut stream,block,deadline).with_context(||format!("TCP send at {done}/{size} bytes"))?;
        } else {bounded_read(&mut stream,block,deadline).with_context(||format!("TCP receive at {done}/{size} bytes"))?;}
        sha.update(&*block); done+=n as u32;
        if progress.elapsed()>=Duration::from_secs(5) {println!("  {}: {:.1}/{} МиБ",if mode==b'U'{"Mac → Windows"}else{"Windows → Mac"},done as f64/1048576.0,o.mib);progress=Instant::now();}
    }
    let mut remote=[0;32]; bounded_read(&mut stream,&mut remote,deadline)?;
    ensure!(remote[..]==sha.finalize()[..],"SHA-256 mismatch: corrupted test payload");
    let seconds=started.elapsed().as_secs_f64();
    Ok(json!({"bytes":size,"seconds":seconds,"mbps":size as f64*8.0/seconds/1e6,"sha256_verified":true}))
}
fn route(destination:&str)->Value {
    let Ok(result)=Command::new("/sbin/route").args(["-n","get",destination]).output() else{return Value::Null;};
    if !result.status.success(){return Value::Null;}
    let text=String::from_utf8_lossy(&result.stdout);
    json!({"interface":text.lines().find_map(|line|line.trim().strip_prefix("interface: "))})
}
fn latest_metrics()->Option<(PathBuf,Value)> {
    let home=PathBuf::from(std::env::var_os("HOME")?);
    let legacy=home.join("MyHub/RadminVPN/profile");
    let profile=std::env::var_os("RADMIN_PROFILE_DIR").map(PathBuf::from).unwrap_or_else(||
        if legacy.is_dir() { legacy } else { home.join("Library/Application Support/Radmin VPN/profile") });
    let dir=profile.join("performance");
    let path=fs::read_dir(dir).ok()?.filter_map(|e|e.ok()).filter(|e|e.file_name().to_string_lossy().starts_with("metrics-"))
        .max_by_key(|e|e.metadata().and_then(|m|m.modified()).ok())?.path();
    let text=fs::read_to_string(&path).ok()?;
    let value=text.lines().rev().find_map(|s|serde_json::from_str::<Value>(s).ok())?;
    Some((path,value))
}
fn save(path:&Path,value:&Value)->Result<()> {
    let mut file=fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    serde_json::to_writer_pretty(&mut file,value)?;file.write_all(b"\n")?;Ok(())
}
fn main()->Result<()> {
    let o=options()?;
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&o.output)?;
    let until=Instant::now()+Duration::from_secs(480);
    let before=latest_metrics();
    let mut report=json!({"version":env!("CARGO_PKG_VERSION"),"label":o.label,"source":o.source,"peer":o.peer,"mib":o.mib,"rounds":[],
        "vpn_route_before":route(&o.peer.to_string()),"default_route_before":route("1.1.1.1"),"local_fixture":o.loopback,
        "engine_before":before.as_ref().map(|(_,v)|v),"started_unix_ms":SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis()});
    println!("Проверка {} → {}. Отчёт: {}",o.source,o.peer,o.output.display());
    save(&o.output.join("initial.json"),&report)?;
    println!("UDP без нагрузки…");
    report["udp_idle"]=udp(o.source,o.peer,o.port,Some(10),Arc::default(),until,None);
    let stop=Arc::new(AtomicBool::new(false));let cancel=stop.clone();let (source,peer,port)=(o.source,o.peer,o.port);
    let (ready,started)=std::sync::mpsc::sync_channel(1);
    let load=thread::spawn(move||udp(source,peer,port,None,cancel,until,Some(ready)));
    let _=started.recv_timeout(Duration::from_secs(2));
    let mut all_transfers_ok=true;
    for round in 1..=o.rounds {
        let mut result=json!({"round":round});
        for (name,mode) in [("upload",b'U'),("download",b'D')] {
            println!("Раунд {round}/{}: {}…",o.rounds,if mode==b'U'{"Mac → Windows"}else{"Windows → Mac"});
            result[name]=match transfer(&o,mode,until) {Ok(v)=>{println!("  {:.2} Мбит/с, SHA-256 OK",v["mbps"].as_f64().unwrap());v},Err(e)=>{all_transfers_ok=false;println!("  Ошибка: {e:#}");json!({"error":format!("{e:#}")})}};
            save(&o.output.join(format!("round-{round}-{name}.json")),&result[name])?;
        }
        report["rounds"].as_array_mut().unwrap().push(result);
    }
    stop.store(true,Ordering::Relaxed);report["udp_under_load"]=load.join().unwrap_or_else(|_|json!({"error":"UDP worker stopped"}));
    report["udp_after"]=udp(o.source,o.peer,o.port,Some(10),Arc::default(),until,None);
    report["vpn_route_after"]=route(&o.peer.to_string());report["default_route_after"]=route("1.1.1.1");
    if let Some((path,after))=latest_metrics() {
        let same=before.as_ref().is_some_and(|(old,_)|old==&path); report["engine_after"]=after.clone();report["same_engine_session"]=json!(same);
        let fresh=after["unix_ms"].as_u64().zip(report["started_unix_ms"].as_u64()).is_some_and(|(last,start)|last>=start);
        report["engine_metrics_fresh"]=json!(fresh);
        if same && fresh {let previous=&before.as_ref().unwrap().1["traffic"];
            let mut delta=serde_json::Map::new();if let Some(fields)=after["traffic"].as_object(){for (key,value) in fields {if let (Some(a),Some(b))=(value.as_u64(),previous[key].as_u64()){delta.insert(key.clone(),json!(a.saturating_sub(b)));}}}
            report["engine_traffic_delta"]=Value::Object(delta);
        }
    }
    report["all_transfers_sha256_verified"]=json!(all_transfers_ok);
    let udp_healthy=["udp_idle","udp_under_load","udp_after"].iter().all(|key|report[key]["received"].as_u64().is_some_and(|n|n>0) && report[key]["loss_percent"].as_f64().is_some_and(|loss|loss<=5.0));
    report["verdict"]=json!(if !all_transfers_ok {"failed"} else if !udp_healthy {"warning"} else {"ok"});
    report["finished_unix_ms"]=json!(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis());
    save(&o.output.join("report.json"),&report)?;
    let mut text=format!("Условия: {}\nMac: {}\nWindows: {}\n",o.label,o.source,o.peer);
    for round in report["rounds"].as_array().unwrap() {for (key,title) in [("upload","Mac → Windows"),("download","Windows → Mac")] {
        text+=&format!("Раунд {} {title}: {}\n",round["round"],if let Some(speed)=round[key]["mbps"].as_f64(){format!("{speed:.2} Мбит/с; SHA-256 OK")}else{round[key]["error"].to_string()});
    }}
    for (key,title) in [("udp_idle","UDP до нагрузки"),("udp_under_load","UDP под нагрузкой"),("udp_after","UDP после нагрузки")] {
        if let Some(error)=report[key]["error"].as_str(){text+=&format!("{title}: ошибка {error}\n");continue;}
        let number=|name:&str|report[key][name].as_f64().map(|v|format!("{v:.1}")).unwrap_or_else(||"—".into());
        text+=&format!("{title}: {}/{} ответов, потери {}%, медиана {} мс, p95 {} мс\n",report[key]["received"],report[key]["sent"],number("loss_percent"),number("median_ms"),number("p95_ms"));
    }
    if report["engine_traffic_delta"].is_object() {
        text+=&format!("Движок за тест: отброшено {} кадров, ожиданий окна UDP {}\n",report["engine_traffic_delta"]["dropped"],report["engine_traffic_delta"]["congestion_waits"]);
    }
    text+=&format!("Итог: {}\n",match report["verdict"].as_str(){Some("ok")=>"передачи и UDP-проверки прошли",Some("warning")=>"данные целы, есть потери UDP или проблемы с его проверкой",_=>"есть ошибки передачи"});
    text+="\nЭто скорость данного маршрута. При смене условий запустите отдельный тест с новым названием.\nОтчёт не содержит паролей или содержимого пользовательских файлов.\n";
    let mut file=fs::OpenOptions::new().create_new(true).write(true).mode(0o600).open(o.output.join("Результат.txt"))?;file.write_all(text.as_bytes())?;
    println!("\n{text}\nОтчёт сохранён: {}",o.output.display());
    if !all_transfers_ok {std::process::exit(1);} if !udp_healthy {std::process::exit(2);} Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    #[test]
    fn a_short_socket_timeout_does_not_discard_a_partial_block() {
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        let mut local=TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (mut remote,_)=listener.accept().unwrap();
        let worker=thread::spawn(move|| {remote.write_all(b"AB").unwrap();thread::sleep(Duration::from_millis(3200));remote.write_all(b"CD").unwrap();});
        let mut bytes=[0;4];
        bounded_read(&mut local,&mut bytes,Instant::now()+Duration::from_secs(8)).unwrap();
        assert_eq!(&bytes,b"ABCD"); worker.join().unwrap();
    }
    #[test]
    fn an_unresponsive_socket_still_obeys_the_total_deadline() {
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        let mut local=TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (_remote,_)=listener.accept().unwrap();
        let started=Instant::now();
        assert!(bounded_read(&mut local,&mut [0;4],started+Duration::from_millis(150)).is_err());
        assert!(started.elapsed()<Duration::from_secs(2));
    }
}
