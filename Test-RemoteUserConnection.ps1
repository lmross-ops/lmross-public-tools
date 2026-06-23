# Test-RemoteUserConnection.ps1
# Quick sanity check for remote/hotspot/bad coffee shop wifi

$ErrorActionPreference = 'SilentlyContinue'

Write-Host "Testing your connection, hang tight..." -ForegroundColor Cyan

# --- Connection type detection ---
$activeAdapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } | Select-Object -First 1
$connType = switch -Wildcard ($activeAdapter.InterfaceDescription) {
    '*Wireless*'   { 'Wi-Fi' }
    '*Wi-Fi*'      { 'Wi-Fi' }
    '*WiFi*'       { 'Wi-Fi' }
    '*Bluetooth*'  { 'Bluetooth tether (yikes)' }
    '*Cellular*'   { 'Cellular/Hotspot' }
    '*Mobile*'     { 'Cellular/Hotspot' }
    default        { $activeAdapter.InterfaceDescription }
}

# Wi-Fi signal strength if applicable
$signal = $null
if ($connType -eq 'Wi-Fi') {
    $netshOutput = netsh wlan show interfaces
    $signalLine = $netshOutput | Select-String 'Signal'
    if ($signalLine) {
        $signal = ($signalLine -split ':')[1].Trim()
    }
    $ssidLine = $netshOutput | Select-String '^\s+SSID\s+:'
    if ($ssidLine) {
        $ssid = ($ssidLine -split ':',2)[1].Trim()
    }
}

# --- Latency + packet loss ---
$pingTargets = @('1.1.1.1','8.8.8.8')
$pingResults = foreach ($t in $pingTargets) {
    $p = Test-Connection -ComputerName $t -Count 10 -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Target = $t
        AvgMs  = if ($p) { [math]::Round(($p | Measure-Object ResponseTime -Average).Average,0) } else { $null }
        Loss   = if ($p) { [math]::Round((10 - $p.Count) / 10 * 100, 0) } else { 100 }
    }
}
$avgLatency = [math]::Round(($pingResults.AvgMs | Where-Object { $_ } | Measure-Object -Average).Average, 0)
$avgLoss    = [math]::Round(($pingResults.Loss | Measure-Object -Average).Average, 0)


# --- Rough download estimate (no dependencies) ---
$dl = $null
try {
    Write-Host "Estimating download speed..." -ForegroundColor Cyan
    $sizeMB = 10
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-WebRequest -Uri "https://speed.cloudflare.com/__down?bytes=$($sizeMB * 1MB)" `
        -UseBasicParsing -TimeoutSec 30
    $sw.Stop()
    $dl = [math]::Round(($sizeMB * 8) / $sw.Elapsed.TotalSeconds, 1)
} catch {
    $dl = 0
}


# --- Verdict logic ---
$problems = @()
$verdict  = 'GOOD'

if ($avgLatency -gt 150)              { $problems += "High latency ($avgLatency ms) — expect lag in Teams/RDP/VoIP"; $verdict = 'BAD' }
elseif ($avgLatency -gt 80)           { $problems += "Elevated latency ($avgLatency ms) — noticeable in calls"; $verdict = 'MARGINAL' }

if ($avgLoss -gt 5)                   { $problems += "Packet loss at $avgLoss% — calls will drop and freeze"; $verdict = 'BAD' }
elseif ($avgLoss -gt 1)               { $problems += "Minor packet loss ($avgLoss%)"; if ($verdict -eq 'GOOD') { $verdict = 'MARGINAL' } }

if ($dl -eq 0)                        { $problems += "Download test failed entirely — connection is severely degraded or blocked"; $verdict = 'BAD' }
elseif ($dl -lt 5)                    { $problems += "Download $dl Mbps — too slow for video calls"; $verdict = 'BAD' }
elseif ($dl -lt 15)                   { $problems += "Download $dl Mbps — okay for email, painful for everything else"; if ($verdict -eq 'GOOD') { $verdict = 'MARGINAL' } }

if ($signal -and ($signal -replace '%','') -as [int] -lt 50) {
    $problems += "Weak Wi-Fi signal ($signal) — move closer to the router/AP"
    if ($verdict -eq 'GOOD') { $verdict = 'MARGINAL' }
}

# --- Build the report ---
$headerArt = switch ($verdict) {
    'GOOD'     { "  CONNECTION LOOKS FINE  " }
    'MARGINAL' { "  CONNECTION IS MARGINAL  " }
    'BAD'      { "  CONNECTION IS THE PROBLEM  " }
}

$report = @"
==================================================
$headerArt
==================================================

Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer:  $env:COMPUTERNAME
User:      $env:USERNAME

CONNECTION
----------
Type:        $connType
$(if ($ssid)   { "Network:     $ssid" })
$(if ($signal) { "Signal:      $signal" })

RESULTS
-------
Latency:     $avgLatency ms
Packet Loss: $avgLoss %
Download:    $(if ($dl -eq 0) { 'FAILED' } else { "$dl Mbps" })

DIAGNOSIS
---------
$(if ($problems) { ($problems | ForEach-Object { "  - $_" }) -join "`r`n" } else { "  No significant issues detected. The problem is elsewhere — please contact LMRoss support with this report." })

$(if ($verdict -eq 'BAD') {@"

WHAT TO DO
----------
Your current connection is not good enough for reliable
remote work. Before calling support, please try:

  1. Move closer to the Wi-Fi router (or switch to Ethernet)
  2. Try a different Wi-Fi network entirely
  3. If on a phone hotspot: move to a window or outside
  4. Restart your hotspot / router
  5. Try again from a coffee shop, library, or home

If you're still having issues on a KNOWN GOOD connection,
then contact LMRoss support and include this report.
"@})

==================================================
Save or screenshot this report if contacting support.
==================================================
"@

$path = "$env:TEMP\LMR-ConnectionTest-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$report | Out-File -FilePath $path -Encoding UTF8

# Open results for user
Start-Process notepad.exe $path

# Return JSON for activity log if run via RMM
[PSCustomObject]@{
    Verdict     = $verdict
    Latency     = $avgLatency
    PacketLoss  = $avgLoss
    DownloadMbps= $dl
    ConnType    = $connType
    Signal      = $signal
    Problems    = $problems
} | ConvertTo-Json -Compress