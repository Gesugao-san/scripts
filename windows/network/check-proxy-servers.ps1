#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Quick health check of proxy servers: ping, TCP ports and a generate_204 probe.

.DESCRIPTION
  Checks every address of every server and prints one colored table,
  a row per address, as soon as that address is checked:
    - Ping: ICMP echo requests, "replied/sent" and average round-trip time.
    - TCP <port>: TCP connect to every port from -Ports (22 and 443 by default).
      "refused" means the host is alive but nothing listens on the port;
      "timeout" means the host is down or the port is filtered.
  Colors: green - OK, yellow - partial (some pings lost / some checks failed), red - failed.
  The address column shows the overall state of its row.

  After the table, requests -ProbeUrl (Google generate_204) once, expecting HTTP 204.
  Without -Proxy the probe uses this machine's normal route (router, podkop, etc.);
  with -Proxy the request goes through the given HTTP proxy.

  Servers are given as groups of addresses:
    - in arguments: name=ip1,ip2 or name=ip1 ip2; addresses after a name belong to it
      until the next name=; addresses before any name go to the "-" group;
    - in a list file (-ListFile): a line [name] starts a group, the following lines hold
      its addresses (one or more per line); '#' starts a comment.

  Works in Windows PowerShell 5.1 and PowerShell 7+ (Windows/Linux/macOS).

.PARAMETER Ip
  Servers and addresses, see DESCRIPTION.

.PARAMETER ListFile
  Text file with servers and addresses, see DESCRIPTION.

.PARAMETER Ports
  TCP ports to check. Default: 22, 443.

.PARAMETER TimeoutMs
  Timeout for a single ping or TCP connect, in milliseconds. Default: 3000.

.PARAMETER PingCount
  Number of echo requests per address. Default: 4.

.PARAMETER ProbeUrl
  URL for the final HTTP check. Default: https://www.google.com/generate_204.

.PARAMETER HttpTimeoutSec
  Timeout for the final HTTP check, in seconds. Default: 10.

.PARAMETER Proxy
  Optional HTTP proxy for the final check, e.g. http://127.0.0.1:2080.

.EXAMPLE
  .\check-proxy-servers.ps1 -ListFile .\servers.txt

.EXAMPLE
  .\check-proxy-servers.ps1 de=203.0.113.10,203.0.113.11 nl=198.51.100.7

.EXAMPLE
  .\check-proxy-servers.ps1 -ListFile .\servers.txt -PingCount 2 -TimeoutMs 1500 -Ports 22,443,8443

.NOTES
  Exit code: 0 when nothing failed (yellow is not a failure), 1 when any check failed,
  2 when no addresses were given.
  Many VPS providers drop ICMP, so a failed ping alone does not mean the host is down.
  An open port 443 only proves that something accepts TCP there, not that the proxy core works.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0, ValueFromRemainingArguments)]
  [string[]] $Ip,

  [string] $ListFile,

  [ValidateRange(1, 65535)]
  [int[]] $Ports = @(22, 443),

  [ValidateRange(100, 60000)]
  [int] $TimeoutMs = 3000,

  [ValidateRange(1, 100)]
  [int] $PingCount = 4,

  [string] $ProbeUrl = 'https://www.google.com/generate_204',

  [ValidateRange(1, 300)]
  [int] $HttpTimeoutSec = 10,

  [string] $Proxy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Console color for every check level
$LevelColor = @{
  Ok   = 'Green'
  Warn = 'Yellow'
  Fail = 'Red'
}

# Short table texts for common socket errors; anything else is shown as its lowercased code
$SocketErrorText = @{
  ConnectionRefused  = 'refused'
  TimedOut           = 'timeout'
  HostUnreachable    = 'unreachable'
  NetworkUnreachable = 'no route'
  HostNotFound       = 'dns error'
  NoData             = 'dns error'
  TryAgain           = 'dns error'
  AccessDenied       = 'denied'
}

# Width of every check column in the table
$CellWidth = 11

<#
.SYNOPSIS
  Turns an exception into a short text that fits a table cell.
.PARAMETER Exception
  Exception thrown by a ping or a TCP connect.
#>
function Get-ShortError {
  param([System.Exception] $Exception)
  $base = $Exception.GetBaseException()
  if ($base -isnot [System.Net.Sockets.SocketException]) {
    return 'error'
  }
  $code = $base.SocketErrorCode.ToString()
  if ($SocketErrorText.ContainsKey($code)) {
    return $SocketErrorText[$code]
  }
  $code.ToLowerInvariant()
}

<#
.SYNOPSIS
  Reads a text file as lines, detecting its encoding.
.DESCRIPTION
  Windows PowerShell 5.1 reads files without a BOM as ANSI, which breaks UTF-8 text
  (e.g. Cyrillic server names). This function honors a BOM (UTF-8/16/32), otherwise
  decodes strictly as UTF-8 and falls back to the system ANSI code page
  (e.g. Windows-1251) only when the bytes are not valid UTF-8.
.PARAMETER Path
  Path to the file.
.OUTPUTS
  Lines of the file.
#>
function Read-TextLines {
  param([string] $Path)
  $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
  $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
  $reader = [System.IO.StreamReader]::new($fullPath, $strictUtf8, $true)
  try {
    $text = $reader.ReadToEnd()
  } catch {
    # Not valid UTF-8: a legacy ANSI file, e.g. saved by old Notepad as Windows-1251
    $ansi = [System.Text.Encoding]::GetEncoding([cultureinfo]::CurrentCulture.TextInfo.ANSICodePage)
    $text = $ansi.GetString([System.IO.File]::ReadAllBytes($fullPath))
  } finally {
    $reader.Dispose()
  }
  $text -split '\r?\n'
}

<#
.SYNOPSIS
  Collects servers and their addresses from arguments and an optional list file.
.PARAMETER Inline
  Arguments: name=ip1,ip2 groups and/or bare addresses.
.PARAMETER FilePath
  Optional list file with [name] sections; '#' starts a comment.
.OUTPUTS
  Objects with Name and Addresses (unique, in the order given); empty groups are skipped.
#>
function Get-ServerList {
  param(
    [string[]] $Inline,
    [string] $FilePath
  )
  # Flatten everything into tokens: "name=" starts a group, anything else is an address
  $tokens = [System.Collections.Generic.List[string]]::new()
  foreach ($item in @($Inline | Where-Object { $_ })) {
    $tokens.AddRange([string[]] ($item -split '[,;\s]+'))
  }
  if ($FilePath) {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
      throw "List file not found: $FilePath"
    }
    foreach ($line in Read-TextLines -Path $FilePath) {
      $line = ($line -replace '#.*$', '').Trim()
      if ($line -match '^\[(?<name>.+)\]$') {
        # Section names may contain spaces, so they are not split
        $tokens.Add("$($Matches.name.Trim())=")
        continue
      }
      $tokens.AddRange([string[]] ($line -split '[,;\s]+'))
    }
  }

  $groups = [ordered]@{}
  $current = '-'
  foreach ($token in $tokens) {
    if (-not $token) {
      continue
    }
    if ($token -match '^(?<name>[^=]+)=(?<rest>.*)$') {
      $current = $Matches.name.Trim()
      $token = $Matches.rest
      if (-not $token) {
        continue
      }
    }
    if (-not $groups.Contains($current)) {
      $groups[$current] = [System.Collections.Generic.List[string]]::new()
    }
    if ($groups[$current].Contains($token)) {
      continue
    }
    $groups[$current].Add($token)
  }

  foreach ($name in $groups.Keys) {
    [pscustomobject]@{ Name = $name; Addresses = $groups[$name].ToArray() }
  }
}

<#
.SYNOPSIS
  Creates a check result: a level (Ok, Warn, Fail) and a short text for the table.
#>
function New-Check {
  param(
    [ValidateSet('Ok', 'Warn', 'Fail')]
    [string] $Level,
    [string] $Text
  )
  [pscustomobject]@{ Level = $Level; Text = $Text }
}

<#
.SYNOPSIS
  Sends ICMP echo requests and reports how many came back.
.PARAMETER Target
  IP address or host name.
.PARAMETER Count
  Number of echo requests.
.PARAMETER Timeout
  Timeout per request, in milliseconds.
#>
function Test-Ping {
  param(
    [string] $Target,
    [int] $Count,
    [int] $Timeout
  )
  $pinger = [System.Net.NetworkInformation.Ping]::new()
  $lastError = $null
  try {
    $replies = foreach ($i in 1..$Count) {
      try {
        $pinger.Send($Target, $Timeout)
      } catch {
        $lastError = Get-ShortError $_.Exception
      }
    }
  } finally {
    $pinger.Dispose()
  }

  $success = @($replies | Where-Object { $_ -and $_.Status -eq 'Success' })
  if ($success.Count -eq 0) {
    $text = if ($lastError) { $lastError } else { "0/$Count" }
    return New-Check 'Fail' $text
  }

  $avg = [math]::Round(($success | Measure-Object -Property RoundtripTime -Average).Average)
  $level = if ($success.Count -eq $Count) { 'Ok' } else { 'Warn' }
  New-Check $level "$($success.Count)/$Count ${avg}ms"
}

<#
.SYNOPSIS
  Tries to open a TCP connection to the given port.
.PARAMETER Target
  IP address or host name.
.PARAMETER Port
  TCP port.
.PARAMETER Timeout
  Connect timeout, in milliseconds.
#>
function Test-TcpPort {
  param(
    [string] $Target,
    [int] $Port,
    [int] $Timeout
  )
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $finished = $client.ConnectAsync($Target, $Port).Wait($Timeout)
    $watch.Stop()
  } catch {
    # Wait() throws when the connect fails fast (refused, unreachable, DNS error)
    return New-Check 'Fail' (Get-ShortError $_.Exception)
  } finally {
    $client.Dispose()
  }

  if (-not $finished) {
    return New-Check 'Fail' 'timeout'
  }
  New-Check 'Ok' "$($watch.ElapsedMilliseconds)ms"
}

<#
.SYNOPSIS
  Requests a generate_204-style URL and expects HTTP 204.
.PARAMETER Url
  URL to request.
.PARAMETER TimeoutSec
  Request timeout, in seconds.
.PARAMETER ProxyUrl
  Optional HTTP proxy.
#>
function Test-Generate204 {
  param(
    [string] $Url,
    [int] $TimeoutSec,
    [string] $ProxyUrl
  )
  $request = @{
    Uri                = $Url
    UseBasicParsing    = $true
    TimeoutSec         = $TimeoutSec
    MaximumRedirection = 0
  }
  if ($ProxyUrl) {
    $request.Proxy = $ProxyUrl
  }

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $response = Invoke-WebRequest @request
  } catch {
    return New-Check 'Fail' $_.Exception.GetBaseException().Message
  }
  $watch.Stop()

  $code = [int] $response.StatusCode
  if ($code -ne 204) {
    # Anything else usually means a captive portal, DPI stub page or a redirect
    return New-Check 'Fail' "HTTP $code, expected 204"
  }
  New-Check 'Ok' "HTTP 204 in $($watch.ElapsedMilliseconds) ms"
}

<#
.SYNOPSIS
  Prints one table row; every cell is padded (or cut) to its width and colored.
.PARAMETER Cells
  Hashtables with Text, Width and Color.
#>
function Write-Row {
  param([object[]] $Cells)
  foreach ($cell in $Cells) {
    $text = [string] $cell.Text
    if ($text.Length -gt $cell.Width) {
      $text = $text.Substring(0, $cell.Width)
    }
    Write-Host ($text.PadRight($cell.Width) + '  ') -NoNewline -ForegroundColor $cell.Color
  }
  Write-Host ''
}

# --- Main -------------------------------------------------------------------

$servers = @(Get-ServerList -Inline $Ip -FilePath $ListFile)
if ($servers.Count -eq 0) {
  Write-Host 'No addresses given: pass them as arguments or use -ListFile.' -ForegroundColor Red
  exit 2
}

$nameWidth = [int] [math]::Max(6, ($servers | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
$ipWidth = [int] [math]::Max(7, ($servers | ForEach-Object { $_.Addresses } | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)
$columns = @('Ping') + @($Ports | ForEach-Object { "TCP $_" })
$lineWidth = $nameWidth + $ipWidth + $columns.Count * $CellWidth + ($columns.Count + 1) * 2
$separator = '-' * $lineWidth

$header = @(
  @{ Text = 'Server'; Width = $nameWidth; Color = 'White' }
  @{ Text = 'Address'; Width = $ipWidth; Color = 'White' }
) + @($columns | ForEach-Object { @{ Text = $_; Width = $CellWidth; Color = 'White' } })
Write-Row $header

$totalChecks = 0
$failedChecks = 0
foreach ($server in $servers) {
  Write-Host $separator -ForegroundColor DarkGray
  $label = $server.Name

  foreach ($address in $server.Addresses) {
    $checks = @(Test-Ping -Target $address -Count $PingCount -Timeout $TimeoutMs) +
      @(foreach ($port in $Ports) { Test-TcpPort -Target $address -Port $port -Timeout $TimeoutMs })

    $okCount = @($checks | Where-Object { $_.Level -eq 'Ok' }).Count
    $totalChecks += $checks.Count
    $failedChecks += @($checks | Where-Object { $_.Level -eq 'Fail' }).Count
    $rowLevel = 'Warn'
    if ($okCount -eq $checks.Count) { $rowLevel = 'Ok' }
    if ($okCount -eq 0) { $rowLevel = 'Fail' }

    $row = @(
      @{ Text = $label; Width = $nameWidth; Color = 'Cyan' }
      @{ Text = $address; Width = $ipWidth; Color = $LevelColor[$rowLevel] }
    ) + @($checks | ForEach-Object { @{ Text = $_.Text; Width = $CellWidth; Color = $LevelColor[$_.Level] } })
    Write-Row $row

    # Show the server name only on its first row
    $label = ''
  }
}
Write-Host $separator -ForegroundColor DarkGray

$route = if ($Proxy) { "via $Proxy" } else { 'default route' }
$probe = Test-Generate204 -Url $ProbeUrl -TimeoutSec $HttpTimeoutSec -ProxyUrl $Proxy
Write-Host ('generate_204 ({0}): {1}' -f $route, $probe.Text) -ForegroundColor $LevelColor[$probe.Level]
$totalChecks++
if ($probe.Level -eq 'Fail') { $failedChecks++ }

if ($failedChecks -gt 0) {
  Write-Host "$failedChecks of $totalChecks checks failed" -ForegroundColor Red
  exit 1
}
Write-Host "All $totalChecks checks passed" -ForegroundColor Green
exit 0

