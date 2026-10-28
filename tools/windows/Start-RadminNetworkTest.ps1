param(
    [string]$BindAddress,
    [string]$AllowedPeer,
    [int]$Port = 48671,
    [ValidateRange(30,600)][int]$Seconds = 300,
    [switch]$Interactive
)
# Application-level test server for two owned Radmin endpoints. No installation,
# firewall changes, saved payloads, account access or elevated privileges.
$ErrorActionPreference = 'Stop'
if ($Interactive) {
    Write-Host 'Keep Radmin and your normal VPN enabled on BOTH computers.'
    $BindAddress = (Read-Host 'Windows Radmin IP (26.x.x.x)').Trim()
    $AllowedPeer = (Read-Host 'Mac Radmin IP (26.x.x.x)').Trim()
}
if (-not $BindAddress -or -not $AllowedPeer) { throw 'Specify BindAddress and AllowedPeer, or use -Interactive.' }
foreach ($Address in @($BindAddress, $AllowedPeer)) {
    $Parsed = [System.Net.IPAddress]::Parse($Address)
    if ($Parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $Parsed.GetAddressBytes()[0] -ne 26) { throw 'Use assigned Radmin IPv4 addresses.' }
}
if (-not ('RadminMacNetworkTest' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
public static class RadminMacNetworkTest {
    static readonly byte[] Magic = System.Text.Encoding.ASCII.GetBytes("RVMAC001");
    static void ReadExact(NetworkStream stream, byte[] buffer, int count) {
        int offset = 0;
        while(offset < count) {
            int read = stream.Read(buffer, offset, count-offset);
            if(read == 0) throw new System.IO.EndOfStreamException();
            offset += read;
        }
    }
    static bool HasMagic(byte[] bytes) {
        if(bytes.Length < 12) return false;
        for(int i=0;i<8;i++) if(bytes[i] != Magic[i]) return false;
        return true;
    }
    public static void Run(string bindAddress, string allowedPeer, int port, int seconds) {
        var bind = IPAddress.Parse(bindAddress);
        var allowed = IPAddress.Parse(allowedPeer);
        var listener = new TcpListener(bind,port);
        UdpClient udp = null;
        Task echo = null;
        var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        try {
        listener.ExclusiveAddressUse = true;
        listener.Start(4);
        udp = new UdpClient(AddressFamily.InterNetwork);
        udp.ExclusiveAddressUse = true;
        udp.Client.Bind(new IPEndPoint(bind,port));
        udp.Client.ReceiveTimeout = 500;
        echo = Task.Run(() => {
            while(!cancel.IsCancellationRequested) {
                try {
                    IPEndPoint remote = new IPEndPoint(IPAddress.Any,0);
                    byte[] bytes = udp.Receive(ref remote);
                    if(remote.Address.Equals(allowed) && bytes.Length <= 1400 && HasMagic(bytes))
                        udp.Send(bytes,bytes.Length,remote);
                } catch(SocketException e) {
                    // A late reply to a closed probe socket can cause an ICMP
                    // reset on Windows. Keep serving subsequent test runs.
                    if(e.SocketErrorCode != SocketError.TimedOut && e.SocketErrorCode != SocketError.ConnectionReset && e.SocketErrorCode != SocketError.ConnectionRefused) break;
                } catch(ObjectDisposedException) { break; }
            }
        });
        Console.WriteLine("Ready: TCP + UDP " + bindAddress + ":" + port + "; allowed peer " + allowedPeer);
        Console.WriteLine("Stops automatically after " + seconds + " seconds. Ctrl+C also stops it.");
            while(!cancel.IsCancellationRequested) {
                if(!listener.Pending()) { Thread.Sleep(20); continue; }
                using(var client = listener.AcceptTcpClient()) {
                    if(!((IPEndPoint)client.Client.RemoteEndPoint).Address.Equals(allowed)) continue;
                    client.NoDelay = true;
                    client.ReceiveTimeout = client.SendTimeout = 30000;
                    try {
                        using(var stream = client.GetStream())
                        using(var sha = SHA256.Create())
                        using(var random = RandomNumberGenerator.Create()) {
                            byte[] header = new byte[13];
                            ReadExact(stream,header,13);
                            if(!HasMagic(header) || (header[8] != 85 && header[8] != 68)) continue;
                            uint size = ((uint)header[9]<<24)|((uint)header[10]<<16)|((uint)header[11]<<8)|header[12];
                            if(size == 0 || size > 64*1024*1024) continue;
                            byte[] buffer = new byte[65536];
                            uint done = 0;
                            while(done < size && !cancel.IsCancellationRequested) {
                                int count = (int)Math.Min((uint)buffer.Length,size-done);
                                if(header[8] == 85) ReadExact(stream,buffer,count);
                                else { random.GetBytes(buffer); stream.Write(buffer,0,count); }
                                sha.TransformBlock(buffer,0,count,buffer,0);
                                done += (uint)count;
                            }
                            if(done != size) continue;
                            sha.TransformFinalBlock(new byte[0],0,0);
                            stream.Write(sha.Hash,0,32);
                            Console.WriteLine((header[8] == 85 ? "Upload" : "Download") + ": " + done + " bytes; SHA-256 sent");
                        }
                    } catch(Exception e) { Console.WriteLine("Test connection: " + e.GetType().Name); }
                }
            }
        } finally {
            cancel.Cancel(); listener.Stop();
            if(udp != null) udp.Close();
            try { if(echo != null) echo.Wait(1000); } catch(AggregateException) {}
            cancel.Dispose();
        }
    }
}
'@
}
try {
    [RadminMacNetworkTest]::Run($BindAddress, $AllowedPeer, $Port, $Seconds)
} catch {
    $Cause = $_.Exception
    while ($Cause.InnerException) { $Cause = $Cause.InnerException }
    if ($Cause -is [System.Net.Sockets.SocketException] -and
        $Cause.SocketErrorCode -eq [System.Net.Sockets.SocketError]::AddressAlreadyInUse) {
        Write-Host "Test port ${BindAddress}:$Port is already in use (TCP or UDP)." -ForegroundColor Yellow
        Write-Host 'An earlier test server may still be running. If its window shows Ready, leave it open and run Start-Mac-Test.command on the Mac.'
        Write-Host 'To restart, close only the old test-server window, then launch this script again. Do not stop unrelated programs.'
        exit 2
    }
    Write-Host ('Test server failed: ' + $Cause.Message) -ForegroundColor Red
    exit 1
}
