# SPDX-License-Identifier: GPL-3.0-only
# Run locally in an elevated Windows 10/11 PowerShell on a test computer.
# Uses the built-in, Microsoft-supplied PktMon. No downloads or uploads.
# Full NIC capture can include traffic from other applications: use a test session.
# Reference: https://learn.microsoft.com/windows-server/administration/windows-commands/pktmon-start
# Reference: https://learn.microsoft.com/windows-server/administration/windows-commands/pktmon-etl2pcap
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path ([Environment]::GetFolderPath('Desktop')) (
        'RadminCapture-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$ErrorActionPreference = 'Stop'
$pktmon = Join-Path $env:SystemRoot 'System32\pktmon.exe'
if (-not (Test-Path -LiteralPath $pktmon)) { throw 'PktMon not found. Windows 10/11 with Packet Monitor is required.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Choose a new output directory; existing files are preserved.' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$etl = Join-Path $OutputDirectory 'radmin.etl'
$pcap = Join-Path $OutputDirectory 'radmin.pcapng'
$events = Join-Path $OutputDirectory 'events.txt'
function Mark([string]$Name) {
    $line = [DateTimeOffset]::Now.ToString('o') + ' ' + $Name
    Add-Content -LiteralPath $events -Value $line -Encoding UTF8
    Write-Host $line
}

$metadata = [ordered]@{
    osVersion = [Environment]::OSVersion.VersionString
    capture = 'Full packets on NICs, local-only; no upload'
    radmin = @()
}
$paths = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) |
    Where-Object { -not [string]::IsNullOrEmpty($_) } |
    Select-Object -Unique |
    ForEach-Object { Join-Path $_ 'Radmin VPN\RvControlSvc.exe' }
foreach ($path in $paths) {
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path
        $metadata.radmin += [ordered]@{
            file = 'RvControlSvc.exe'
            version = $item.VersionInfo.FileVersion
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    }
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'metadata.json') -Encoding UTF8
& $pktmon filter list | Out-File -LiteralPath (Join-Path $OutputDirectory 'existing-filters.txt') -Encoding UTF8
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing PktMon filters.' }

Write-Host 'Use a private test network and close unrelated network applications.'
Write-Host 'Existing PktMon filters are recorded, not changed. An existing capture is not stopped.'
Write-Host 'During the capture: restart Radmin on the test computer, join the test network, then ping a test peer.'
Write-Host 'No network passwords are requested by this script.'
$null = Read-Host 'Press Enter when ready to start the local capture'
$started = $false
try {
    & $pktmon start --capture --comp nics --pkt-size 0 --file-name $etl --file-size 256 --log-mode circular
    if ($LASTEXITCODE -ne 0) { throw 'PktMon could not start. Any pre-existing capture is left untouched.' }
    $started = $true
    Mark 'capture-start'
    $null = Read-Host 'Restart Radmin on the test PC, wait until online, then press Enter'
    Mark 'registration-online-observed-by-user'
    $null = Read-Host 'Join the private test network in Radmin, then press Enter'
    Mark 'joined-test-network-observed-by-user'
    $null = Read-Host 'Ping a test peer, wait 10 seconds, then press Enter to stop capture'
    Mark 'peer-test-finished'
} finally {
    if ($started) {
        & $pktmon stop
        if ($LASTEXITCODE -ne 0) { Write-Warning 'PktMon stop failed. Check pktmon status manually.' }
        Mark 'capture-stop-requested'
    }
}
& $pktmon etl2pcap $etl --out $pcap
if ($LASTEXITCODE -ne 0) { throw 'PCAPNG conversion failed; the original ETL has been retained.' }
Write-Host ('Capture saved locally: ' + $OutputDirectory)
Write-Host 'Review the capture before sharing it. No files were uploaded.'
