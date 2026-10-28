// SPDX-License-Identifier: GPL-3.0-only
//! macOS utun boundary. The elevated Swift helper owns only interface I/O;
//! OpenRad authentication, membership and packet validation stay unprivileged.
use anyhow::{bail, ensure, Context, Result};
use std::{collections::VecDeque, fs, io::{self, Read, Write}, net::Ipv4Addr,
    os::{fd::AsRawFd, unix::{fs::{DirBuilderExt, PermissionsExt}, net::{UnixListener, UnixStream}}},
    path::Path, process::{Child, Command, Stdio}, sync::{atomic::{AtomicBool, Ordering}, Mutex},
    time::{Duration, Instant}};
pub const NAME: &str = "utun";
const SERVICE_SOCKET: &str = "/private/var/run/radmin-vpn-mac/bridge.sock";
const LIMIT: usize = crate::tunnel::MAX_FRAME;

struct BridgeIo { stream: UnixStream, input: Vec<u8>, output: VecDeque<Vec<u8>>, offset: usize }
impl BridgeIo {
    fn flush(&mut self) -> io::Result<()> {
        while let Some(frame) = self.output.front() {
            match self.stream.write(&frame[self.offset..]) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => { self.offset += n; if self.offset == frame.len() { self.output.pop_front(); self.offset=0; } },
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
    fn length(&self) -> Result<Option<usize>> {
        if self.input.len() < 4 { return Ok(None); }
        let n = u32::from_be_bytes(self.input[..4].try_into()?) as usize;
        ensure!((14..=LIMIT).contains(&n), "invalid local Ethernet frame length");
        Ok(Some(n))
    }
    fn complete(&self) -> Result<bool> { Ok(self.length()?.is_some_and(|n| self.input.len() >= n+4)) }
}
pub struct Tap { io: Mutex<BridgeIo>, child: Option<Child> }
fn shell_quote(value: &str) -> String { format!("'{}'", value.replace('\'', "'\\''")) }
fn apple_string(value: &str) -> String { format!("\"{}\"",value.replace('\\',"\\\\").replace('"',"\\\"")) }
fn check(stop: &AtomicBool, until: Instant) -> Result<()> {
    ensure!(!stop.load(Ordering::Relaxed), "Interface setup cancelled");
    ensure!(Instant::now() < until, "Interface authorization timed out");
    Ok(())
}
fn request_service(socket: &Path, nonce: &str, vip: Ipv4Addr, stop: &AtomicBool) -> Result<bool> {
    let until = Instant::now() + Duration::from_secs(5);
    let mut service = loop { match UnixStream::connect(SERVICE_SOCKET) {
        Ok(stream) => break stream,
        Err(error) if error.kind() == io::ErrorKind::NotFound && !Path::new("/Library/LaunchDaemons/dev.radminvpn.mac.bridge.plist").exists() => return Ok(false),
        Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused) && Instant::now() < until && !stop.load(Ordering::Relaxed) => { std::thread::sleep(Duration::from_millis(50)); },
        Err(error) => return Err(error).context("Installed adapter service is unavailable; reinstall it from connection settings"),
    }
    };
    let (mut uid, mut gid) = (u32::MAX, u32::MAX);
    ensure!(unsafe {libc::getpeereid(service.as_raw_fd(), &mut uid, &mut gid)} == 0 && uid == 0, "Adapter service is not root-owned");
    service.set_read_timeout(Some(Duration::from_secs(3)))?;
    service.set_write_timeout(Some(Duration::from_secs(3)))?;
    let data = serde_json::to_vec(&serde_json::json!({"socket":socket,"nonce":nonce,"vip":vip.to_string()}))?;
    ensure!(data.len() <= 2048, "Adapter request too large");
    service.write_all(b"RVS1")?;
    service.write_all(&(data.len() as u32).to_be_bytes())?;
    service.write_all(&data)?;
    let mut response = [255]; service.read_exact(&mut response)?;
    ensure!(response[0] == 0, "Adapter service is busy; disconnect the other Radmin session first");
    Ok(true)
}
impl Tap {
    pub fn create(vip: Ipv4Addr, peers: &[Ipv4Addr]) -> Result<Self> {
        Self::create_with_helper(vip,peers,&std::env::current_exe()?.with_file_name("radmin-bridge"))
    }
    pub fn create_with_helper(vip: Ipv4Addr, _peers: &[Ipv4Addr], helper: &Path) -> Result<Self> {
        Self::create_lan_with_helper(vip,helper)
    }
    pub fn create_lan_with_helper(vip: Ipv4Addr, helper: &Path) -> Result<Self> {
        Self::create_lan_with_helper_cancellable(vip,helper,&AtomicBool::new(false))
    }
    pub(crate) fn create_lan_with_helper_cancellable(vip: Ipv4Addr, helper: &Path, stop: &AtomicBool) -> Result<Self> {
        ensure!(vip.octets()[0] == 26, "Radmin IPv4 address required");
        ensure!(helper.is_file(), "Native radmin-bridge helper is missing");
        let helper = helper.canonicalize()?;
        let run = std::path::PathBuf::from(std::env::var_os("RADMIN_RUN_DIR").context("RADMIN_RUN_DIR is required")?);
        let nonce = hex::encode(crate::crypto::random(16));
        let directory = run.join(format!("utun-{}",&nonce[..12]));
        fs::DirBuilder::new().mode(0o700).create(&directory)?;
        let socket = directory.join("bridge.sock");
        ensure!(socket.as_os_str().len() < 104, "Local socket path is too long");
        let listener = UnixListener::bind(&socket)?;
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        let arguments = [helper.to_string_lossy().into_owned(),"--serve".into(),
            "--socket".into(),socket.to_string_lossy().into_owned(),"--nonce".into(),nonce.clone(),
            "--vip".into(),vip.to_string(),"--owner".into(),unsafe {libc::getuid()}.to_string()];
        let command = arguments.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" ");
        let script = format!("do shell script {} with administrator privileges",apple_string(&command));
        let mut child = if request_service(&socket, &nonce, vip, stop)? { None } else {
            Some(Command::new("/usr/bin/osascript").args(["-e", &script])
                .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn()?)
        };
        let result = (|| -> Result<Self> {
            let until = Instant::now()+Duration::from_secs(180);
            let mut stream = loop {
                check(stop,until)?;
                if let Some(child) = &mut child { if child.try_wait()?.is_some() { bail!("Administrator authorization was cancelled or native interface setup failed"); } }
                match listener.accept() {
                    Ok((stream,_)) => break stream,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(50)),
                    Err(e) => return Err(e.into()),
                }
            };
            let (mut uid,mut gid) = (u32::MAX,u32::MAX);
            ensure!(unsafe {libc::getpeereid(stream.as_raw_fd(),&mut uid,&mut gid)} == 0 && uid == 0,
                "Interface helper is not privileged");
            stream.set_read_timeout(Some(Duration::from_millis(200)))?;
            let mut response = [0u8;33];
            let mut filled=0;
            while filled < response.len() {
                check(stop,until)?;
                match stream.read(&mut response[filled..]) {
                    Ok(0) => bail!("Native helper closed during interface setup"),
                    Ok(n) => filled+=n,
                    Err(e) if matches!(e.kind(),io::ErrorKind::WouldBlock|io::ErrorKind::TimedOut|io::ErrorKind::Interrupted) => (),
                    Err(e) => return Err(e.into()),
                }
            }
            ensure!(response[..32] == *nonce.as_bytes(), "Native helper setup response rejected");
            if response[32] == 0 {
                stream.set_read_timeout(Some(Duration::from_secs(3)))?;
                let mut length=[0;4];
                stream.read_exact(&mut length)?;
                let size=u32::from_be_bytes(length) as usize;
                ensure!(size<=2048,"Native helper diagnostic exceeds limit");
                let mut message=vec![0;size];
                stream.read_exact(&mut message)?;
                bail!("Native interface setup: {}",String::from_utf8_lossy(&message));
            }
            ensure!(response[32] == 1,"Native helper setup response rejected");
            stream.set_nonblocking(true)?;
            // Child is moved out below only after all fallible setup is complete.
            Ok(Self {io:Mutex::new(BridgeIo {stream,input:Vec::new(),output:VecDeque::new(),offset:0}), child:None})
        })();
        drop(listener);
        let _ = fs::remove_file(&socket);
        let _ = fs::remove_dir(&directory);
        match result {
            Ok(mut tap) => { tap.child=child; Ok(tap) },
            Err(error) => { if let Some(child) = &mut child { let _=child.kill(); let _=child.wait(); } Err(error) },
        }
    }
    pub fn ready(&self, timeout: i32) -> Result<bool> {
        let mut state=self.io.lock().map_err(|_| anyhow::anyhow!("interface lock poisoned"))?;
        state.flush()?;
        Ok(state.complete()? || crate::session::readable(state.stream.as_raw_fd(),timeout)?)
    }
    pub(crate) fn poll_fd(&self) -> Option<i32> { self.io.lock().ok().map(|io| io.stream.as_raw_fd()) }
    pub fn receive(&mut self) -> Result<Vec<u8>> {
        let io=self.io.get_mut().map_err(|_| anyhow::anyhow!("interface lock poisoned"))?;
        io.flush()?;
        while !io.complete()? {
            let mut bytes=[0;4096];
            let n=io.stream.read(&mut bytes)?;
            ensure!(n!=0,"Native interface helper disconnected");
            io.input.extend_from_slice(&bytes[..n]);
            ensure!(io.input.len() <= 65536,"Local interface input budget exceeded");
        }
        let n=io.length()?.unwrap();
        let frame=io.input[4..4+n].to_vec();
        io.input.drain(..4+n);
        Ok(frame)
    }
    pub fn send(&mut self, frame: &[u8]) -> Result<()> {
        ensure!((14..=LIMIT).contains(&frame.len()),"Local Ethernet MTU exceeded");
        let io=self.io.get_mut().map_err(|_| anyhow::anyhow!("interface lock poisoned"))?;
        io.flush()?;
        ensure!(io.output.len()<256,"Local interface send queue full");
        io.output.push_back([(frame.len() as u32).to_be_bytes().as_slice(),frame].concat());
        io.flush()?;
        Ok(())
    }
}
impl Drop for Tap {
    fn drop(&mut self) {
        if let Ok(io)=self.io.get_mut() { let _=io.stream.shutdown(std::net::Shutdown::Both); }
        if let Some(mut child)=self.child.take() {
            std::thread::spawn(move || {let _=child.wait();});
        }
    }
}
pub fn helper(_: Ipv4Addr, _: u32, _: &[Ipv4Addr]) -> Result<()> { bail!("Use the native Swift radmin-bridge helper on macOS") }
pub fn helper_with_lan(vip: Ipv4Addr, owner:u32, peers:&[Ipv4Addr], _:bool) -> Result<()> { helper(vip,owner,peers) }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn partial_headers_and_coalesced_frames_preserve_order() {
        let (stream, mut peer)=UnixStream::pair().unwrap();
        stream.set_nonblocking(true).unwrap();
        let mut tap=Tap {io:Mutex::new(BridgeIo {stream,input:Vec::new(),output:VecDeque::new(),offset:0}),child:None};
        let frames=[vec![1;60],vec![2;1514]];
        let wire:Vec<u8>=frames.iter().flat_map(|frame| [(frame.len() as u32).to_be_bytes().as_slice(),frame].concat()).collect();
        peer.write_all(&wire[..3]).unwrap();
        assert!(tap.receive().unwrap_err().downcast_ref::<io::Error>().is_some_and(|e| e.kind()==io::ErrorKind::WouldBlock));
        peer.write_all(&wire[3..]).unwrap();
        assert_eq!(tap.receive().unwrap(),frames[0]);
        assert!(tap.ready(0).unwrap());
        assert_eq!(tap.receive().unwrap(),frames[1]);
        assert!(!tap.ready(0).unwrap());
        drop(peer);
        assert!(tap.receive().is_err());
    }
    #[test]
    fn malformed_local_lengths_are_rejected_before_allocation() {
        let (stream,_peer)=UnixStream::pair().unwrap();
        let mut io=BridgeIo {stream,input:vec![0,0,0,13],output:VecDeque::new(),offset:0};
        assert!(io.length().is_err());
        io.input=vec![0,0,5,235]; // 1515 exceeds the negotiated MTU.
        assert!(io.length().is_err());
    }
    #[test]
    fn backpressure_preserves_partially_written_frame_boundaries() {
        let (stream,mut peer)=UnixStream::pair().unwrap();
        stream.set_nonblocking(true).unwrap();
        peer.set_nonblocking(true).unwrap();
        let mut state=BridgeIo {stream,input:Vec::new(),output:VecDeque::new(),offset:0};
        let expected:Vec<u8>=(0..=255).flat_map(|v| vec![v;1518]).collect();
        for frame in expected.chunks(1518) {state.output.push_back(frame.to_vec());}
        state.flush().unwrap();
        let mut received=Vec::new();
        let until=Instant::now()+Duration::from_secs(5);
        while received.len()<expected.len() {
            assert!(Instant::now()<until);
            state.flush().unwrap();
            let mut bytes=[0;997];
            match peer.read(&mut bytes) {
                Ok(n) => received.extend_from_slice(&bytes[..n]),
                Err(e) if e.kind()==io::ErrorKind::WouldBlock => (),
                Err(e) => panic!("{e}"),
            }
        }
        assert_eq!(received,expected);
        assert!(state.output.is_empty());
        assert_eq!(state.offset,0);
    }
}
