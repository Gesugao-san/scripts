#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Quick health check of proxy servers: ping, TCP ports, TLS, DNS records and connectivity probes.

.DESCRIPTION
  Checks every address of every server and prints one colored table,
  a row per address, as soon as that address is checked:
    - Ping: ICMP echo requests, "replied/sent" and average round-trip time.
    - TCP <port>: TCP connect to every port from -Ports (22 and 443 by default).
      "refused" means the host is alive but nothing listens on the port;
      "timeout" means the host is down or the port is filtered.
    - TLS <port>: TLS handshake like openssl s_client -connect ip:443 -servername name,
      with SNI = -TlsServerName or else the server's first domain name; the certificate
      chain and name are checked. "1.3 89d" is the TLS version and the days the
      certificate is still valid (yellow below 14 days). Without a name no SNI is sent
      and only the chain is checked. Turn it off with -NoTls.
  Then a row per domain name of the server: the domain is resolved (A and AAAA)
  and every returned address must be one of the server's IP addresses from the list.
    - DNS m/n: m of the n returned addresses belong to the server.
    - TLS: the same TLS check with SNI = the domain, against the first returned address
      of the server (or the first returned address at all).
    - Every returned address follows, green when it belongs to the server, red when not,
      yellow when it looks like FakeIP (198.18.0.0/15, e.g. from podkop/sing-box).
  Colors: green - OK, yellow - partial (some pings lost / some checks failed), red - failed.
  The address column shows the overall state of its row.

  Domains are resolved with doggo when it is installed (it also speaks DoT, DoH and DoQ,
  see -DnsServer). Without doggo the script offers to install it with Scoop, then falls back
  to Resolve-DnsName (Windows), dig or nslookup, whichever is found first.

  After the table, sends all connectivity probes at once and prints one line per probe:
    - captive-portal checks of Google, Cloudflare, Microsoft, Apple, Mozilla, GNOME, Debian
      and Ubuntu: each expects its own status code and, for some, its own text, so a
      redirect, a DPI stub page or a blocked host shows up as a red line;
    - exit IP services (Amazon, ipify, icanhazip, Cloudflare trace): they show the public
      address the request left from, marked "= <server>" when it is one of the servers
      from the list, so you can see which proxy (if any) the route goes through.
  -Probe picks some of them, -ProbeUrl adds own generate_204-style URLs, -NoProbe skips them.
  Without -Proxy the probes use this machine's normal route (router, podkop, system proxy);
  with -Proxy they go through the given HTTP proxy. Redirects are not followed.

  Every run is also saved as plain text (the same table, without colors) to
  results\<yyyy-MM-dd_HH-mm-ss>.txt next to the script, or to -OutDir; -NoSave turns that off.

  Servers are given as groups of IP addresses and domain names (anything that is not
  an IP address is treated as a domain name to check):
    - in arguments: name=ip1,ip2,domain or name=ip1 ip2 domain; entries after a name belong
      to it until the next name=; entries before any name go to the "-" group;
    - in a list file (-ListFile): a line [name] starts a group, the following lines hold
      its entries (one or more per line); '#' starts a comment.

  Works in Windows PowerShell 5.1 and PowerShell 7+ (Windows/Linux/macOS).

.PARAMETER Ip
  Servers, addresses and domain names, see DESCRIPTION.

.PARAMETER ListFile
  Text file with servers, addresses and domain names, see DESCRIPTION.

.PARAMETER Ports
  TCP ports to check. Default: 22, 443.

.PARAMETER TimeoutMs
  Timeout for a single ping or TCP connect, in milliseconds. Default: 3000.

.PARAMETER PingCount
  Number of echo requests per address. Default: 4.

.PARAMETER NoTls
  Skip the TLS checks.

.PARAMETER TlsPort
  Port for the TLS checks. Default: 443.

.PARAMETER TlsServerName
  SNI for the TLS check of every IP address, e.g. the serverName of a VLESS Reality inbound.
  Default: the first domain name of the server, or no SNI when it has none.

.PARAMETER DnsServer
  DNS server for the domain checks. Default: the system's DNS servers (usually the router).
  Any resolver takes an IP address or host name; doggo also takes tcp://, tls://, https://
  and quic:// addresses, e.g. https://cloudflare-dns.com/dns-query.

.PARAMETER Resolver
  Tool for the domain checks: auto (default: doggo, then Resolve-DnsName, dig, nslookup),
  doggo, Resolve-DnsName, dig or nslookup.

.PARAMETER DnsTimeoutSec
  Timeout for a DNS query, in seconds. Default: 5. Resolve-DnsName has no timeout setting.

.PARAMETER NoInstallPrompt
  Do not offer to install doggo when it is missing; just fall back to another resolver.

.PARAMETER Probe
  Names of the connectivity probes to run (see $ProbeCatalog in the script). Default: all.

.PARAMETER ProbeUrl
  Extra probe URLs of your own, each expected to answer HTTP 204.

.PARAMETER NoProbe
  Skip the connectivity probes.

.PARAMETER HttpTimeoutSec
  Timeout for each connectivity probe, in seconds. Default: 10.

.PARAMETER Proxy
  Optional HTTP proxy for the connectivity probes, e.g. http://127.0.0.1:2080.

.EXAMPLE
  .\check-proxy-servers.ps1 -ListFile .\servers.txt

.EXAMPLE
  .\check-proxy-servers.ps1 de=203.0.113.10,203.0.113.11,de.example.com nl=198.51.100.7

.EXAMPLE
  .\check-proxy-servers.ps1 -ListFile .\servers.txt -DnsServer https://cloudflare-dns.com/dns-query

.EXAMPLE
  .\check-proxy-servers.ps1 reality=203.0.113.10 -TlsServerName www.microsoft.com

.EXAMPLE
  .\check-proxy-servers.ps1 -ListFile .\servers.txt -PingCount 2 -TimeoutMs 1500 -Ports 22,443,8443

.EXAMPLE
  .\check-proxy-servers.ps1 -ListFile .\servers.txt -Probe google,amazon-ip,cloudflare-trace -Proxy http://127.0.0.1:2080

.PARAMETER OutDir
  Folder for the saved results. Default: the results folder next to this script.

.PARAMETER NoSave
  Do not save the results to a file.

.NOTES
  Exit code: 0 when nothing failed (yellow is not a failure), 1 when any check failed,
  2 when nothing to check was given or the options do not fit together.
  Many VPS providers drop ICMP, so a failed ping alone does not mean the host is down.
  An open port 443 only proves that something accepts TCP there, not that the proxy core works.
  The system's DNS behind podkop may answer with FakeIP addresses for proxied domains:
  check those against a public resolver with -DnsServer.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive tool: the colored console table is its output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-Check only builds a result object, it changes no state.')]
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

  [switch] $NoTls,

  [ValidateRange(1, 65535)]
  [int] $TlsPort = 443,

  [string] $TlsServerName,

  [string] $DnsServer,

  [ValidateSet('auto', 'doggo', 'Resolve-DnsName', 'dig', 'nslookup')]
  [string] $Resolver = 'auto',

  [ValidateRange(1, 60)]
  [int] $DnsTimeoutSec = 5,

  [switch] $NoInstallPrompt,

  [string[]] $Probe,

  [string[]] $ProbeUrl,

  [switch] $NoProbe,

  [ValidateRange(1, 300)]
  [int] $HttpTimeoutSec = 10,

  [string] $Proxy,

  [string] $OutDir,

  [switch] $NoSave
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

# TLS versions as SslStream reports them -> short text for the table
# (12288 is TLS 1.3 on .NET Framework builds whose SslProtocols enum has no Tls13 name)
$TlsVersionText = @{
  Tls13   = '1.3'
  '12288' = '1.3'
  Tls12   = '1.2'
  Tls11   = '1.1'
  Tls     = '1.0'
  Ssl3    = 'SSL3'
}

# Certificate problems in the order they are reported -> short text for the table
$TlsErrorText = [ordered]@{
  RemoteCertificateNotAvailable = 'no cert'
  RemoteCertificateNameMismatch = 'wrong name'
  RemoteCertificateChainErrors  = 'untrusted'
}

# Days of certificate validity left below which the TLS cell turns yellow
$CertWarnDays = 14

# Longest error text shown in a domain row
$MaxErrorLength = 60

# Connectivity probes: name -> URL, expected status, optional body pattern and the function
# that reads the answer. The captive-portal URLs are the ones OSes and browsers use themselves;
# several are plain HTTP on purpose, as there a captive portal or DPI can tamper with them.
$ProbeCatalog = [ordered]@{
  'google'           = @{ Url = 'https://www.google.com/generate_204'; Status = 204; Reader = 'Read-StatusProbe' }
  'gstatic'          = @{ Url = 'http://connectivitycheck.gstatic.com/generate_204'; Status = 204; Reader = 'Read-StatusProbe' }
  'cloudflare'       = @{ Url = 'https://cp.cloudflare.com/generate_204'; Status = 204; Reader = 'Read-StatusProbe' }
  'edge'             = @{ Url = 'http://edge-http.microsoft.com/captiveportal/generate_204'; Status = 204; Reader = 'Read-StatusProbe' }
  'windows'          = @{ Url = 'http://www.msftconnecttest.com/connecttest.txt'; Status = 200; Body = '^Microsoft Connect Test$'; Reader = 'Read-StatusProbe' }
  'apple'            = @{ Url = 'http://captive.apple.com/hotspot-detect.html'; Status = 200; Body = '(?<=<TITLE>)Success(?=</TITLE>)'; Reader = 'Read-StatusProbe' }
  'firefox'          = @{ Url = 'http://detectportal.firefox.com/success.txt'; Status = 200; Body = '^success$'; Reader = 'Read-StatusProbe' }
  'firefox-204'      = @{ Url = 'http://firefox-portal-detection.com/generate_204'; Status = 204; Reader = 'Read-StatusProbe' }
  'gnome'            = @{ Url = 'https://nmcheck.gnome.org/check_network_status.txt'; Status = 200; Body = '^NetworkManager is online$'; Reader = 'Read-StatusProbe' }
  'debian'           = @{ Url = 'http://network-test.debian.org/nm'; Status = 200; Body = '^NetworkManager is online$'; Reader = 'Read-StatusProbe' }
  'ubuntu'           = @{ Url = 'http://connectivity-check.ubuntu.com/'; Status = 204; Reader = 'Read-StatusProbe' }
  'amazon-ip'        = @{ Url = 'https://checkip.amazonaws.com/'; Status = 200; Reader = 'Read-ExitIpProbe' }
  'ipify'            = @{ Url = 'https://api.ipify.org/'; Status = 200; Reader = 'Read-ExitIpProbe' }
  'icanhazip'        = @{ Url = 'https://icanhazip.com/'; Status = 200; Reader = 'Read-ExitIpProbe' }
  'cloudflare-trace' = @{ Url = 'https://www.cloudflare.com/cdn-cgi/trace'; Status = 200; Reader = 'Read-TraceProbe' }
}

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
  Shortens a message to its first line and at most -Length characters.
#>
function Get-ShortText {
  param(
    [string] $Text,
    [int] $Length = $MaxErrorLength
  )
  $line = ([string] $Text -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 1)
  if (-not $line) {
    return 'error'
  }
  $line = $line.Trim()
  if ($line.Length -le $Length) {
    return $line
  }
  $line.Substring(0, $Length - 3) + '...'
}

<#
.SYNOPSIS
  Tells whether a string is an IPv4 address in dotted form or an IPv6 address.
.DESCRIPTION
  IPAddress.TryParse alone also accepts forms like "10" or "1.2", which in a server list
  are much more likely typos or host names, so IPv4 must have four parts.
#>
function Test-IpAddress {
  param([string] $Text)
  $parsed = $null
  if (-not [System.Net.IPAddress]::TryParse($Text, [ref] $parsed)) {
    return $false
  }
  if ($Text.Contains(':')) {
    return $true
  }
  $Text -match '^\d{1,3}(\.\d{1,3}){3}$'
}

<#
.SYNOPSIS
  Returns the canonical text form of an IP address, so that equal addresses compare equal.
#>
function ConvertTo-CanonicalIp {
  param([string] $Text)
  [System.Net.IPAddress]::Parse($Text).ToString()
}

<#
.SYNOPSIS
  Tells whether an address is in 198.18.0.0/15, the range sing-box (podkop) uses for FakeIP.
#>
function Test-FakeIp {
  param([string] $Address)
  $Address -match '^198\.(18|19)\.'
}

<#
.SYNOPSIS
  Tells whether a command (exe, script or cmdlet) is available.
#>
function Test-Command {
  param([string] $Name)
  [bool] (Get-Command -Name $Name -ErrorAction SilentlyContinue)
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
function Read-TextFile {
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
  Collects servers with their IP addresses and domain names from arguments and a list file.
.PARAMETER Inline
  Arguments: name=entry1,entry2 groups and/or bare entries.
.PARAMETER FilePath
  Optional list file with [name] sections; '#' starts a comment.
.OUTPUTS
  Objects with Name, Addresses (IP addresses) and Domains (everything else),
  unique and in the order given; empty groups are skipped.
#>
function Get-ServerList {
  param(
    [string[]] $Inline,
    [string] $FilePath
  )
  # Flatten everything into tokens: "name=" starts a group, anything else is an entry
  $tokens = [System.Collections.Generic.List[string]]::new()
  foreach ($item in @($Inline | Where-Object { $_ })) {
    $tokens.AddRange([string[]] ($item -split '[,;\s]+'))
  }
  if ($FilePath) {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
      throw "List file not found: $FilePath"
    }
    foreach ($line in Read-TextFile -Path $FilePath) {
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
    $entries = $groups[$name]
    [pscustomobject]@{
      Name      = $name
      Addresses = @($entries | Where-Object { Test-IpAddress $_ })
      Domains   = @($entries | Where-Object { -not (Test-IpAddress $_) })
    }
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
  Turns a failed TLS connection or handshake into a short text for a table cell.
#>
function Get-TlsError {
  param(
    [System.Exception] $Exception,
    [bool] $Connected
  )
  $base = $Exception.GetBaseException()
  if (-not $Connected) {
    # Failed before TLS started: the same texts as the TCP columns
    return Get-ShortError $Exception
  }
  if ($base -is [System.Security.Authentication.AuthenticationException]) {
    # Both sides talk TLS but could not agree (protocol versions, ciphers)
    return 'handshake'
  }
  # The server closed the connection, reset it or stopped answering during the handshake:
  # nothing that speaks TLS listens there, or DPI cut the connection
  'no TLS'
}

<#
.SYNOPSIS
  Opens a TLS connection like openssl s_client -servername and checks the certificate.
.DESCRIPTION
  Connects to Target:Port, sends ServerName as SNI and validates the certificate chain
  and, when a server name is given, the name in the certificate. Protocol versions are
  left to the OS (SslProtocols.None), as curl and browsers do. Without ServerName no SNI
  is sent and the name is not checked: the cell then only shows that TLS answers.
.PARAMETER Target
  IP address or host name to connect to.
.PARAMETER Port
  TCP port, usually 443.
.PARAMETER ServerName
  Name for SNI and for the certificate name check; empty for none.
.PARAMETER Timeout
  Timeout for the connect and for each read or write of the handshake, in milliseconds.
.OUTPUTS
  A check: "1.3 89d" (TLS version, days the certificate is still valid), yellow below
  $CertWarnDays days; red with expired, wrong name, untrusted, no cert or a connection error.
#>
function Test-TlsHandshake {
  param(
    [string] $Target,
    [int] $Port,
    [string] $ServerName,
    [int] $Timeout
  )
  # The validation callback only records what .NET found; the decision is made below
  $state = @{ Errors = [System.Net.Security.SslPolicyErrors]::None }
  $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
    # Arguments: sender, certificate, chain, policy errors
    $state.Errors = $args[3]
    $true
  }.GetNewClosure()

  $client = [System.Net.Sockets.TcpClient]::new()
  $ssl = $null
  $connected = $false
  try {
    if (-not $client.ConnectAsync($Target, $Port).Wait($Timeout)) {
      return New-Check 'Fail' 'timeout'
    }
    $connected = $true
    $client.ReceiveTimeout = $Timeout
    $client.SendTimeout = $Timeout
    $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $callback)
    $hostName = if ($ServerName) { $ServerName } else { $Target }
    $ssl.AuthenticateAsClient($hostName, $null, [System.Security.Authentication.SslProtocols]::None, $false)

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
    $days = [int] [math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)
    $protocol = $ssl.SslProtocol.ToString()
    $version = if ($TlsVersionText.ContainsKey($protocol)) { $TlsVersionText[$protocol] } else { $protocol }
  } catch {
    return New-Check 'Fail' (Get-TlsError -Exception $_.Exception -Connected $connected)
  } finally {
    if ($ssl) { $ssl.Dispose() }
    $client.Dispose()
  }

  $errors = $state.Errors
  if (-not $ServerName) {
    # No SNI was sent, so the certificate is not expected to carry this name
    $errors = $errors -band -bnot [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch
  }
  if ($days -lt 0) {
    return New-Check 'Fail' 'expired'
  }
  foreach ($flag in $TlsErrorText.Keys) {
    if ($errors -band [System.Net.Security.SslPolicyErrors] $flag) {
      return New-Check 'Fail' $TlsErrorText[$flag]
    }
  }
  $level = if ($days -lt $CertWarnDays) { 'Warn' } else { 'Ok' }
  New-Check $level "$version ${days}d"
}

<#
.SYNOPSIS
  Runs an external program and returns its standard output lines and exit code.
.DESCRIPTION
  Standard error is dropped: Windows PowerShell 5.1 turns it into terminating errors
  when $ErrorActionPreference is Stop, and the resolvers below report errors on stdout
  or through their exit code anyway.
#>
function Invoke-NativeCommand {
  param(
    [string] $Command,
    [string[]] $Arguments
  )
  $ErrorActionPreference = 'Continue'
  $output = & $Command @Arguments 2>$null
  [pscustomobject]@{
    Output   = @($output | ForEach-Object { [string] $_ })
    ExitCode = $LASTEXITCODE
  }
}

<#
.SYNOPSIS
  Resolves A and AAAA records with doggo (JSON output).
.OUTPUTS
  Returned IP addresses; throws with a short message on errors.
#>
function Resolve-WithDoggo {
  param(
    [string] $Name,
    [string] $Server,
    [int] $TimeoutSec
  )
  $arguments = @($Name, 'A', 'AAAA', '--json', "--timeout=${TimeoutSec}s")
  if ($Server) {
    $arguments += "@$Server"
  }
  $result = Invoke-NativeCommand 'doggo' $arguments
  try {
    $json = ($result.Output -join "`n") | ConvertFrom-Json
  } catch {
    throw "doggo exit code $($result.ExitCode), no JSON output"
  }

  $errorProperty = $json.PSObject.Properties['error']
  if ($errorProperty -and $errorProperty.Value) {
    throw [string] $errorProperty.Value
  }
  $responses = $json.PSObject.Properties['responses']
  if (-not $responses) {
    return
  }
  foreach ($response in @($responses.Value)) {
    foreach ($answer in @($response.answers)) {
      # Answers also hold CNAME targets; only addresses count
      if ($answer -and (Test-IpAddress $answer.address)) {
        $answer.address
      }
    }
  }
}

<#
.SYNOPSIS
  Resolves A and AAAA records with Resolve-DnsName (Windows), skipping hosts file and cache.
.OUTPUTS
  Returned IP addresses; throws with the cmdlet's message on errors.
#>
function Resolve-WithResolveDnsName {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TimeoutSec', Justification = 'All resolvers share one signature; Resolve-DnsName has no timeout setting.')]
  param(
    [string] $Name,
    [string] $Server,
    [int] $TimeoutSec
  )
  $request = @{
    Name        = $Name
    Type        = 'A_AAAA'
    DnsOnly     = $true
    ErrorAction = 'Stop'
  }
  if ($Server) {
    $request.Server = $Server
  }
  foreach ($record in @(Resolve-DnsName @request)) {
    # CNAME and SOA records have no IPAddress property
    if ($record.PSObject.Properties['IPAddress']) {
      $record.IPAddress
    }
  }
}

<#
.SYNOPSIS
  Resolves A and AAAA records with dig +short.
.OUTPUTS
  Returned IP addresses; throws when dig got no reply at all.
#>
function Resolve-WithDig {
  param(
    [string] $Name,
    [string] $Server,
    [int] $TimeoutSec
  )
  $common = @('+short', "+time=$TimeoutSec", '+tries=1')
  if ($Server) {
    $common += "@$Server"
  }
  $noReply = 0
  foreach ($type in 'A', 'AAAA') {
    $result = Invoke-NativeCommand 'dig' ($common + @($Name, $type))
    # dig exits with 9 when no server replied
    if ($result.ExitCode -eq 9) {
      $noReply++
    }
    # +short also prints CNAME targets and ";;" error lines; only addresses count
    $result.Output | ForEach-Object { $_.Trim() } | Where-Object { Test-IpAddress $_ }
  }
  if ($noReply -eq 2) {
    throw 'no reply from the DNS server'
  }
}

<#
.SYNOPSIS
  Resolves a name with nslookup and takes the addresses from its answer section.
.DESCRIPTION
  nslookup first prints the server it asked (Server:/Address:), then an empty line,
  then the answer. Labels are translated on localized Windows, so the answer is found
  by position (after the first empty line) and the addresses by their form, not by label.
.OUTPUTS
  Returned IP addresses.
#>
function Resolve-WithNslookup {
  param(
    [string] $Name,
    [string] $Server,
    [int] $TimeoutSec
  )
  $arguments = @("-timeout=$TimeoutSec", '-retry=1', $Name)
  if ($Server) {
    $arguments += $Server
  }
  $lines = (Invoke-NativeCommand 'nslookup' $arguments).Output
  $inAnswer = $false
  foreach ($line in $lines) {
    if (-not $line.Trim()) {
      $inAnswer = $true
      continue
    }
    if (-not $inAnswer) {
      continue
    }
    $line -split '[\s,]+' | Where-Object { Test-IpAddress $_ }
  }
}

# Resolvers in the order 'auto' tries them: name -> command to look for and function to call
$DnsResolvers = [ordered]@{
  'doggo'           = @{ Command = 'doggo'; Function = 'Resolve-WithDoggo' }
  'Resolve-DnsName' = @{ Command = 'Resolve-DnsName'; Function = 'Resolve-WithResolveDnsName' }
  'dig'             = @{ Command = 'dig'; Function = 'Resolve-WithDig' }
  'nslookup'        = @{ Command = 'nslookup'; Function = 'Resolve-WithNslookup' }
}

<#
.SYNOPSIS
  Tells the user that doggo is missing and, if Scoop is there, offers to install it now.
.PARAMETER NoPrompt
  Only print the hint, never ask.
#>
function Request-DoggoInstall {
  param([switch] $NoPrompt)
  Write-Host 'doggo not found: it is the preferred resolver for the domain checks (it also speaks DoT, DoH, DoQ).' -ForegroundColor Yellow

  $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME 'scoop' }
  $package = if (Test-Path -LiteralPath (Join-Path $scoopRoot 'buckets\gesu')) { 'gesu/doggo' } else { 'doggo' }
  if (-not (Test-Command 'scoop')) {
    $hint = if (Test-Command 'winget') { 'winget install doggo' } else { 'https://github.com/mr-karan/doggo/releases' }
    Write-Host "Install it with: $hint" -ForegroundColor Yellow
    return
  }

  $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
  if ($NoPrompt -or -not $interactive) {
    Write-Host "Install it with: scoop install $package" -ForegroundColor Yellow
    return
  }

  try {
    $answer = Read-Host "Install it now with 'scoop install $package'? [y/N]"
  } catch {
    # -NonInteractive hosts refuse Read-Host
    $answer = ''
  }
  # y/yes, or the Cyrillic d/da (written as char codes: this file stays ASCII for Windows PowerShell 5.1)
  $yes = '^(y|yes|{0}|{0}{1})$' -f [char] 0x0434, [char] 0x0430
  if ($answer -notmatch $yes) {
    return
  }
  $ErrorActionPreference = 'Continue'
  # Out-Host: show the install log without returning it from this function
  & scoop install $package | Out-Host
}

<#
.SYNOPSIS
  Picks the resolver for the domain checks.
.PARAMETER Preferred
  The -Resolver option: auto or a resolver name.
.PARAMETER NoPrompt
  Do not offer to install doggo.
.OUTPUTS
  The resolver name, or nothing when none is available.
#>
function Select-DnsResolver {
  param(
    [string] $Preferred,
    [switch] $NoPrompt
  )
  if ($Preferred -ne 'auto') {
    if (Test-Command $DnsResolvers[$Preferred].Command) {
      return $Preferred
    }
    throw "Resolver '$Preferred' not found."
  }
  if (Test-Command 'doggo') {
    return 'doggo'
  }
  Request-DoggoInstall -NoPrompt:$NoPrompt
  foreach ($name in $DnsResolvers.Keys) {
    if (Test-Command $DnsResolvers[$name].Command) {
      return $name
    }
  }
}

<#
.SYNOPSIS
  Resolves a domain and compares the result with the server's IP addresses.
.PARAMETER Domain
  Domain name to resolve.
.PARAMETER Expected
  Canonical IP addresses of the server.
.PARAMETER ResolverName
  Key in $DnsResolvers, or nothing when no resolver is available.
.OUTPUTS
  Object with Level, Text (for the DNS cell) and Answers (address + level for each returned address).
#>
function Test-DomainRecord {
  param(
    [string] $Domain,
    [string[]] $Expected,
    [string] $ResolverName,
    [string] $Server,
    [int] $TimeoutSec
  )
  $result = [pscustomobject]@{ Level = 'Fail'; Text = ''; Answers = @(); Error = '' }
  if (-not $ResolverName) {
    $result.Text = 'no resolver'
    $result.Error = 'install doggo, dig or nslookup'
    return $result
  }

  try {
    $function = $DnsResolvers[$ResolverName].Function
    $returned = @(& $function -Name $Domain -Server $Server -TimeoutSec $TimeoutSec |
      ForEach-Object { ConvertTo-CanonicalIp $_ } | Select-Object -Unique)
  } catch {
    $result.Text = 'error'
    $result.Error = Get-ShortText $_.Exception.Message
    return $result
  }
  if ($returned.Count -eq 0) {
    $result.Text = 'no answer'
    $result.Error = 'no A/AAAA records (or NXDOMAIN)'
    return $result
  }

  $result.Answers = @(foreach ($address in $returned) {
      $level = 'Fail'
      if (Test-FakeIp $address) { $level = 'Warn' }
      if ($Expected -contains $address) { $level = 'Ok' }
      [pscustomobject]@{ Address = $address; Level = $level }
    })
  $matched = @($result.Answers | Where-Object { $_.Level -eq 'Ok' }).Count
  $result.Text = "DNS $matched/$($returned.Count)"
  if ($Expected.Count -eq 0) {
    $result.Level = 'Warn'
    $result.Error = 'no IP addresses in this group to compare with'
    return $result
  }
  $result.Level = 'Warn'
  if ($matched -eq $returned.Count) { $result.Level = 'Ok' }
  if ($matched -eq 0) { $result.Level = 'Fail' }
  $result
}

<#
.SYNOPSIS
  Builds the list of connectivity probes to run.
.PARAMETER Names
  Probe names from $ProbeCatalog; empty means all of them.
.PARAMETER ExtraUrls
  Own URLs, each expected to answer HTTP 204.
.PARAMETER Skip
  Return no probes at all.
.OUTPUTS
  Objects with Name, Url, Status, Body and Reader; throws on an unknown name.
#>
function Get-ProbeList {
  param(
    [string[]] $Names,
    [string[]] $ExtraUrls,
    [switch] $Skip
  )
  if ($Skip) {
    return
  }
  $selected = @($Names | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
  if ($selected.Count -eq 0) {
    $selected = @($ProbeCatalog.Keys)
  }
  foreach ($name in $selected) {
    if (-not $ProbeCatalog.Contains($name)) {
      throw "Unknown probe '$name'. Known probes: $($ProbeCatalog.Keys -join ', ')"
    }
    $entry = $ProbeCatalog[$name]
    $body = if ($entry.ContainsKey('Body')) { $entry.Body } else { $null }
    [pscustomobject]@{ Name = $name; Url = $entry.Url; Status = $entry.Status; Body = $body; Reader = $entry.Reader }
  }
  foreach ($url in @($ExtraUrls | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })) {
    [pscustomobject]@{ Name = ([uri] $url).Host; Url = $url; Status = 204; Body = $null; Reader = 'Read-StatusProbe' }
  }
}

<#
.SYNOPSIS
  Formats an exit IP and, when it is one of the listed servers, that server's name.
#>
function Format-ExitIp {
  param(
    [string] $Address,
    [string] $Suffix,
    [hashtable] $Owners
  )
  $text = ("$Address $Suffix").Trim()
  $canonical = ConvertTo-CanonicalIp $Address
  if ($Owners.ContainsKey($canonical)) {
    return "$text = $($Owners[$canonical])"
  }
  "$text (not a listed server)"
}

<#
.SYNOPSIS
  Reads a captive-portal probe: the status must match and, if set, the body pattern too.
.OUTPUTS
  Level and Text for the probe line.
#>
function Read-StatusProbe {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExitIpOwners', Justification = 'All probe readers share one signature.')]
  param(
    [pscustomobject] $Probe,
    [System.Net.Http.HttpResponseMessage] $Response,
    [string] $Body,
    [hashtable] $ExitIpOwners
  )
  $code = [int] $Response.StatusCode
  if ($code -ne $Probe.Status) {
    # A redirect is how most captive portals and DPI stub pages answer
    $location = $Response.Headers.Location
    $where = if ($location) { ", redirect to $location" } else { '' }
    return @{ Level = 'Fail'; Text = Get-ShortText "HTTP $code, expected $($Probe.Status)$where" }
  }
  if (-not $Probe.Body) {
    return @{ Level = 'Ok'; Text = "HTTP $code" }
  }
  $found = [regex]::Match($Body.Trim(), $Probe.Body, 'IgnoreCase')
  if (-not $found.Success) {
    return @{ Level = 'Fail'; Text = Get-ShortText "HTTP $code, unexpected text: $($Body.Trim())" }
  }
  @{ Level = 'Ok'; Text = Get-ShortText "HTTP $code `"$($found.Value)`"" }
}

<#
.SYNOPSIS
  Reads an exit IP service that answers with the bare address.
.OUTPUTS
  Level and Text for the probe line.
#>
function Read-ExitIpProbe {
  param(
    [pscustomobject] $Probe,
    [System.Net.Http.HttpResponseMessage] $Response,
    [string] $Body,
    [hashtable] $ExitIpOwners
  )
  $code = [int] $Response.StatusCode
  $address = $Body.Trim()
  if ($code -ne $Probe.Status -or -not (Test-IpAddress $address)) {
    return @{ Level = 'Fail'; Text = Get-ShortText "HTTP $code, no address: $address" }
  }
  @{ Level = 'Ok'; Text = Format-ExitIp -Address $address -Owners $ExitIpOwners }
}

<#
.SYNOPSIS
  Reads Cloudflare's /cdn-cgi/trace: key=value lines with ip= (exit IP) and loc= (country).
.OUTPUTS
  Level and Text for the probe line.
#>
function Read-TraceProbe {
  param(
    [pscustomobject] $Probe,
    [System.Net.Http.HttpResponseMessage] $Response,
    [string] $Body,
    [hashtable] $ExitIpOwners
  )
  $code = [int] $Response.StatusCode
  $fields = @{}
  foreach ($line in $Body -split '\r?\n') {
    if ($line -match '^(?<key>[a-z_]+)=(?<value>.*)$') {
      $fields[$Matches.key] = $Matches.value.Trim()
    }
  }
  if ($code -ne $Probe.Status -or -not $fields.ContainsKey('ip') -or -not (Test-IpAddress $fields.ip)) {
    return @{ Level = 'Fail'; Text = "HTTP $code, no ip= line" }
  }
  $country = if ($fields.ContainsKey('loc')) { $fields.loc } else { '' }
  @{ Level = 'Ok'; Text = Format-ExitIp -Address $fields.ip -Suffix $country -Owners $ExitIpOwners }
}

<#
.SYNOPSIS
  Turns a failed request into a short text: timeout, a socket error or the first line of the message.
#>
function Get-ProbeError {
  param([System.Threading.Tasks.Task] $Task)
  if ($Task.IsCanceled) {
    return 'timeout'
  }
  $base = $Task.Exception.GetBaseException()
  if ($base -is [System.Threading.Tasks.TaskCanceledException] -or $base -is [System.TimeoutException]) {
    return 'timeout'
  }
  if ($base -is [System.Net.Sockets.SocketException]) {
    return Get-ShortError $base
  }
  Get-ShortText $base.Message
}

<#
.SYNOPSIS
  Sends all probes at once and reads every answer with the probe's reader.
.DESCRIPTION
  Requests run in parallel through one HttpClient (no redirects followed), so a dead
  network costs one timeout, not one per probe. The time of each probe is taken when
  its request is seen finished (polled every 10 ms).
.PARAMETER Probes
  Objects from Get-ProbeList.
.PARAMETER TimeoutSec
  Timeout for each request.
.PARAMETER ProxyUrl
  Optional HTTP proxy; without it the system proxy settings apply.
.PARAMETER ExitIpOwners
  Canonical server IP -> server name, to name the server an exit IP belongs to.
.OUTPUTS
  Objects with Name, Time, Level and Text, in the order of -Probes.
#>
function Invoke-ConnectivityProbe {
  param(
    [object[]] $Probes,
    [int] $TimeoutSec,
    [string] $ProxyUrl,
    [hashtable] $ExitIpOwners
  )
  Add-Type -AssemblyName System.Net.Http
  # Windows PowerShell 5.1 may still default to TLS 1.0, which most of these hosts refuse
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

  $handler = [System.Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  if ($ProxyUrl) {
    $handler.Proxy = [System.Net.WebProxy]::new($ProxyUrl)
    $handler.UseProxy = $true
  }
  $client = [System.Net.Http.HttpClient]::new($handler)
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('check-proxy-servers/1.0')

  try {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $pending = @(foreach ($probe in $Probes) {
        [pscustomobject]@{ Probe = $probe; Task = $client.GetAsync($probe.Url); ElapsedMs = -1 }
      })
    while (@($pending | Where-Object { $_.ElapsedMs -lt 0 }).Count -gt 0) {
      foreach ($item in $pending) {
        if ($item.ElapsedMs -lt 0 -and $item.Task.IsCompleted) {
          $item.ElapsedMs = $watch.ElapsedMilliseconds
        }
      }
      Start-Sleep -Milliseconds 10
    }

    foreach ($item in $pending) {
      $line = [pscustomobject]@{ Name = $item.Probe.Name; Time = "$($item.ElapsedMs) ms"; Level = 'Fail'; Text = '' }
      if ($item.Task.IsFaulted -or $item.Task.IsCanceled) {
        $line.Text = Get-ProbeError $item.Task
        $line
        continue
      }
      $response = $item.Task.Result
      try {
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $read = & $item.Probe.Reader -Probe $item.Probe -Response $response -Body $body -ExitIpOwners $ExitIpOwners
      } finally {
        $response.Dispose()
      }
      $line.Level = $read.Level
      $line.Text = $read.Text
      $line
    }
  } finally {
    $client.Dispose()
  }
}

<#
.SYNOPSIS
  Prints one table row; every cell is padded (or cut) to its width and colored.
.PARAMETER Cells
  Hashtables with Text, Width and Color.
#>
function Write-Row {
  param([object[]] $Cells)
  $line = ''
  foreach ($cell in $Cells) {
    $text = [string] $cell.Text
    if ($text.Length -gt $cell.Width) {
      $text = $text.Substring(0, $cell.Width)
    }
    $text = $text.PadRight($cell.Width) + '  '
    Write-Host $text -NoNewline -ForegroundColor $cell.Color
    $line += $text
  }
  Write-Host ''
  $Report.Add($line.TrimEnd())
}

<#
.SYNOPSIS
  Prints a colored line and keeps it, without color, for the saved results.
#>
function Write-ReportLine {
  param(
    [string] $Text,
    [string] $Color = 'Gray'
  )
  Write-Host $Text -ForegroundColor $Color
  $Report.Add($Text)
}

<#
.SYNOPSIS
  Saves the kept lines as a UTF-8 text file named after the start time; prints where.
.DESCRIPTION
  The file has a BOM so that Notepad and Windows PowerShell 5.1 read Cyrillic server
  names correctly. A failed save is reported but does not change the exit code.
.PARAMETER Folder
  Target folder; created when missing.
.PARAMETER Started
  Start time of the run, used for the file name.
#>
function Save-Report {
  param(
    [string] $Folder,
    [datetime] $Started
  )
  try {
    $null = New-Item -ItemType Directory -Path $Folder -Force
    $path = Join-Path (Resolve-Path -LiteralPath $Folder).ProviderPath ($Started.ToString('yyyy-MM-dd_HH-mm-ss') + '.txt')
    [System.IO.File]::WriteAllLines($path, [string[]] $Report, [System.Text.UTF8Encoding]::new($true))
    Write-Host "Saved: $path" -ForegroundColor DarkGray
  } catch {
    Write-Host "Could not save the results: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# --- Main -------------------------------------------------------------------

# Lines of the table without colors, saved at the end (see Save-Report)
$Report = [System.Collections.Generic.List[string]]::new()
$started = Get-Date
$resultsFolder = if ($OutDir) { $OutDir } else { Join-Path $PSScriptRoot 'results' }

$servers = @(Get-ServerList -Inline $Ip -FilePath $ListFile)
if ($servers.Count -eq 0) {
  Write-Host 'Nothing to check: pass addresses and domains as arguments or use -ListFile.' -ForegroundColor Red
  exit 2
}

try {
  $probes = @(Get-ProbeList -Names $Probe -ExtraUrls $ProbeUrl -Skip:$NoProbe)
} catch {
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 2
}

$source = if ($ListFile) { $ListFile } else { 'arguments' }
$Report.Add("check-proxy-servers $($started.ToString('yyyy-MM-dd HH:mm:ss zzz')), $([Environment]::MachineName), servers from $source")

$hasDomains = @($servers | Where-Object { $_.Domains.Count -gt 0 }).Count -gt 0
$resolverName = $null
if ($hasDomains) {
  try {
    $resolverName = Select-DnsResolver -Preferred $Resolver -NoPrompt:$NoInstallPrompt
  } catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 2
  }
  if ($DnsServer -match '^[a-z0-9]+://' -and $resolverName -ne 'doggo') {
    Write-Host "Only doggo understands '$DnsServer'; $resolverName needs a plain IP address or host name." -ForegroundColor Red
    exit 2
  }
  $via = if ($DnsServer) { $DnsServer } else { 'system DNS' }
  $with = if ($resolverName) { $resolverName } else { 'no resolver found' }
  Write-ReportLine "Domains: $with, via $via" 'DarkGray'
}

$entries = @($servers | ForEach-Object { @($_.Addresses) + @($_.Domains) })
$nameWidth = [int] [math]::Max(6, ($servers | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
$ipWidth = [int] [math]::Max(7, ($entries | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)
$columns = @('Ping') + @($Ports | ForEach-Object { "TCP $_" })
if (-not $NoTls) {
  $columns += "TLS $TlsPort"
}
$lineWidth = $nameWidth + $ipWidth + $columns.Count * $CellWidth + ($columns.Count + 1) * 2
$separator = '-' * $lineWidth

$header = @(
  @{ Text = 'Server'; Width = $nameWidth; Color = 'White' }
  @{ Text = 'Address'; Width = $ipWidth; Color = 'White' }
) + @($columns | ForEach-Object { @{ Text = $_; Width = $CellWidth; Color = 'White' } })
Write-Row $header

$totalChecks = 0
$failedChecks = 0
$sawFakeIp = $false
foreach ($server in $servers) {
  Write-ReportLine $separator 'DarkGray'
  $label = $server.Name

  foreach ($address in $server.Addresses) {
    $checks = @(Test-Ping -Target $address -Count $PingCount -Timeout $TimeoutMs) +
      @(foreach ($port in $Ports) { Test-TcpPort -Target $address -Port $port -Timeout $TimeoutMs })
    if (-not $NoTls) {
      $sni = if ($TlsServerName) { $TlsServerName } else { $server.Domains | Select-Object -First 1 }
      $checks += Test-TlsHandshake -Target $address -Port $TlsPort -ServerName $sni -Timeout $TimeoutMs
    }

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

  $expected = @($server.Addresses | ForEach-Object { ConvertTo-CanonicalIp $_ })
  foreach ($domain in $server.Domains) {
    $dns = Test-DomainRecord -Domain $domain -Expected $expected -ResolverName $resolverName -Server $DnsServer -TimeoutSec $DnsTimeoutSec
    $totalChecks++
    if ($dns.Level -eq 'Fail') { $failedChecks++ }
    if (@($dns.Answers | Where-Object { Test-FakeIp $_.Address }).Count -gt 0) { $sawFakeIp = $true }

    $tlsCells = @()
    # Without DNS answers a TLS check by name would only repeat the DNS failure
    if (-not $NoTls -and $dns.Answers.Count -gt 0) {
      # Prefer an address of this server, so the check shows what the server itself presents
      $own = @($dns.Answers | Where-Object { $_.Level -eq 'Ok' } | ForEach-Object { $_.Address })
      $any = @($dns.Answers | ForEach-Object { $_.Address })
      $target = @($own + $any)[0]
      $tls = Test-TlsHandshake -Target $target -Port $TlsPort -ServerName $domain -Timeout $TimeoutMs
      $totalChecks++
      if ($tls.Level -eq 'Fail') { $failedChecks++ }
      $tlsCells = @(@{ Text = "TLS $($tls.Text)"; Width = $CellWidth + 4; Color = $LevelColor[$tls.Level] })
    }

    # Returned addresses and any error follow the DNS cell, each as wide as its text
    $row = @(
      @{ Text = $label; Width = $nameWidth; Color = 'Cyan' }
      @{ Text = $domain; Width = $ipWidth; Color = $LevelColor[$dns.Level] }
      @{ Text = $dns.Text; Width = $CellWidth; Color = $LevelColor[$dns.Level] }
    ) + $tlsCells + @($dns.Answers | ForEach-Object { @{ Text = $_.Address; Width = $_.Address.Length; Color = $LevelColor[$_.Level] } })
    if ($dns.Error) {
      $row += @{ Text = $dns.Error; Width = $dns.Error.Length; Color = $LevelColor[$dns.Level] }
    }
    Write-Row $row
    $label = ''
  }
}
Write-ReportLine $separator 'DarkGray'

if ($sawFakeIp) {
  Write-ReportLine 'Yellow addresses are in 198.18.0.0/15, likely FakeIP from podkop/sing-box: try -DnsServer 1.1.1.1' 'Yellow'
}

if ($probes.Count -gt 0) {
  $route = if ($Proxy) { "via $Proxy" } else { 'default route' }
  Write-ReportLine "Probes ($route)" 'White'
  $exitIpOwners = @{}
  foreach ($server in $servers) {
    foreach ($address in $server.Addresses) {
      $exitIpOwners[(ConvertTo-CanonicalIp $address)] = $server.Name
    }
  }
  $probeWidth = [int] ($probes | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
  foreach ($result in Invoke-ConnectivityProbe -Probes $probes -TimeoutSec $HttpTimeoutSec -ProxyUrl $Proxy -ExitIpOwners $exitIpOwners) {
    $totalChecks++
    if ($result.Level -eq 'Fail') { $failedChecks++ }
    Write-Row @(
      @{ Text = $result.Name; Width = $probeWidth; Color = 'Cyan' }
      @{ Text = $result.Time; Width = 8; Color = 'DarkGray' }
      @{ Text = $result.Text; Width = $result.Text.Length; Color = $LevelColor[$result.Level] }
    )
  }
}

$summary = @{ $true = @("$failedChecks of $totalChecks checks failed", 'Red', 1); $false = @("All $totalChecks checks passed", 'Green', 0) }[$failedChecks -gt 0]
Write-ReportLine $summary[0] $summary[1]
if (-not $NoSave) {
  Save-Report -Folder $resultsFolder -Started $started
}
exit $summary[2]

