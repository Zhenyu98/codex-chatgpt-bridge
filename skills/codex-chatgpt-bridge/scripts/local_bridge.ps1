[CmdletBinding()]
param(
  [ValidateSet("Start", "Stop", "Status", "Doctor", "Rotate")]
  [string]$Action = "Status",

  [string]$ProjectRoot = (Get-Location).Path,

  # UTF-8 JSON string array encoded as Base64 by bridge_controller.ps1.
  [string]$AllowedRootsBase64,

  [ValidateSet("none", "cloudflare", "external", "cloudflare-worker")]
  [string]$Tunnel = "cloudflare",

  [ValidateRange(1, 65535)]
  [int]$Port = 7676,

  [string]$PublicBaseUrl,

  [switch]$InstallCloudflared,

  [switch]$RequireWorkerKv,

  [string]$OperationId,

  [string]$StateDir = (Join-Path $env:LOCALAPPDATA "devspace-bridge"),

  [switch]$DiscoverOrphans
)

$ErrorActionPreference = "Stop"
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
} catch {
  # Non-console hosts may not expose OutputEncoding.
}

$BinDir = Join-Path $StateDir "bin"
$LogDir = Join-Path $StateDir "logs"
$StatePath = Join-Path $StateDir "state.json"
$WorkerProxyConfigPath = Join-Path $StateDir "worker-proxy.json"
$CfApiProtectedConfigPath = Join-Path $StateDir "cf-api.protected.json"
$CloudflaredPath = Join-Path $BinDir "cloudflared.exe"
$NpmBin = Join-Path $env:APPDATA "npm"
$DevspaceCmd = Join-Path $NpmBin "devspace.cmd"
$GitBashDir = "C:\Program Files\Git\bin"
$RunId = if ($OperationId) {
  [regex]::Replace($OperationId, "[^A-Za-z0-9_.-]", "_")
} else {
  (Get-Date).ToString("yyyyMMdd-HHmmss-fff")
}

function Ensure-Dirs {
  New-Item -ItemType Directory -Force -Path $StateDir, $BinDir, $LogDir | Out-Null
}

function Write-Json($obj) {
  $json = $obj | ConvertTo-Json -Depth 8
  [Console]::Out.WriteLine($json)
}

function Write-JsonFileAtomic($obj, [string]$path) {
  $json = $obj | ConvertTo-Json -Depth 8
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $tempPath = "$path.$([Guid]::NewGuid().ToString('n')).tmp"
  [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
  try {
    if (Test-Path -LiteralPath $path) {
      $backupPath = "$path.$([Guid]::NewGuid().ToString('n')).bak"
      try {
        [System.IO.File]::Replace($tempPath, $path, $backupPath)
      } finally {
        if (Test-Path -LiteralPath $backupPath) {
          Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
      }
    } else {
      [System.IO.File]::Move($tempPath, $path)
    }
  } finally {
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-CommandLineProcess([string]$pattern) {
  Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and $_.CommandLine -like $pattern } |
    Select-Object ProcessId, CommandLine
}

function Get-ProcessInfoById([int]$processId) {
  if ($processId -le 0) { return $null }
  Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue |
    Select-Object ProcessId, Name, CommandLine
}

function Get-PortOwnerProcesses([int]$portNumber) {
  $owners = @(
    Get-NetTCPConnection -LocalPort $portNumber -State Listen -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty OwningProcess -Unique
  )
  @($owners | ForEach-Object { Get-ProcessInfoById ([int]$_) } | Where-Object { $_ })
}

function Get-ManagedDevspaceProcesses([int]$portNumber) {
  @(
    Get-PortOwnerProcesses $portNumber |
      Where-Object { $_.CommandLine -and $_.CommandLine -like '*@waishnav*devspace*' }
  )
}

function Get-UnrelatedPortOwnerProcesses([int]$portNumber) {
  @(
    Get-PortOwnerProcesses $portNumber |
      Where-Object { -not $_.CommandLine -or $_.CommandLine -notlike '*@waishnav*devspace*' }
  )
}

function Ensure-DpapiType {
  if (-not ("System.Security.Cryptography.ProtectedData" -as [type])) {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
  }
  if (-not ("System.Security.Cryptography.ProtectedData" -as [type])) {
    throw "Windows DPAPI support could not be loaded in this PowerShell runtime."
  }
}

function Test-AbsoluteHttpsUrl([string]$url) {
  if (-not $url) { return $false }
  $parsed = $null
  if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsed)) { return $false }
  return (
    $parsed.Scheme -eq "https" -and
    -not [string]::IsNullOrWhiteSpace($parsed.Host) -and
    [string]::IsNullOrWhiteSpace($parsed.UserInfo) -and
    [string]::IsNullOrWhiteSpace($parsed.Query) -and
    [string]::IsNullOrWhiteSpace($parsed.Fragment)
  )
}

function Get-State {
  if (Test-Path $StatePath) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::ReadAllText($StatePath, $utf8) | ConvertFrom-Json
  }
}

function Save-State($state) {
  Ensure-Dirs
  Write-JsonFileAtomic $state $StatePath
}

function Get-WorkerProxyConfig {
  if (-not (Test-Path $WorkerProxyConfigPath)) {
    return $null
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::ReadAllText($WorkerProxyConfigPath, $utf8) | ConvertFrom-Json
}

function Get-CfApiConfig {
  if (Test-Path $CfApiProtectedConfigPath) {
    Ensure-DpapiType
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $protected = [System.IO.File]::ReadAllText($CfApiProtectedConfigPath, $utf8) | ConvertFrom-Json
    if (-not $protected.accountId -or -not $protected.apiTokenProtected) {
      throw "Invalid protected Cloudflare API config: $CfApiProtectedConfigPath"
    }
    $cipherBytes = [Convert]::FromBase64String([string]$protected.apiTokenProtected)
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
      $cipherBytes,
      $null,
      [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    try {
      return [pscustomobject]@{
        accountId = [string]$protected.accountId
        apiToken = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        kvNamespaceId = [string]$protected.kvNamespaceId
        source = "dpapi"
      }
    } finally {
      [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
  }
  return $null
}

# Writes the worker upstream pointer into Cloudflare Workers KV via the REST API
# so a `cloudflare-worker` Start needs no manual browser refresh. Prefer the DPAPI
# `cf-api.protected.json` created by set_cf_api_config.ps1. Plaintext `cf-api.json`
# is intentionally not consumed. Use an account-scoped token holding
# only "Workers KV Storage: Edit". The token is never printed. Returns { ok, reason }
# and never throws so direct Start can degrade while controller Restart stays strict.
function Update-WorkerKv([string]$nsId, [string]$key, [string]$valueJson) {
  $cfg = Get-CfApiConfig
  if (-not $cfg -or -not $cfg.accountId -or -not $cfg.apiToken) {
    return [pscustomobject]@{ ok = $false; reason = "no-cf-api-config" }
  }
  if (-not $nsId) { $nsId = $cfg.kvNamespaceId }
  if (-not $key) { $key = "current" }
  if (-not $nsId) {
    return [pscustomobject]@{ ok = $false; reason = "no-kv-namespace-id" }
  }
  if ([string]$cfg.accountId -notmatch '^[A-Fa-f0-9]{32}$') {
    return [pscustomobject]@{ ok = $false; reason = "invalid-account-id" }
  }
  if ([string]$nsId -notmatch '^[A-Fa-f0-9]{32}$') {
    return [pscustomobject]@{ ok = $false; reason = "invalid-kv-namespace-id" }
  }
  if ([string]::IsNullOrWhiteSpace($key)) {
    return [pscustomobject]@{ ok = $false; reason = "invalid-kv-key" }
  }
  $escapedKey = [Uri]::EscapeDataString($key)
  $uri = "https://api.cloudflare.com/client/v4/accounts/$($cfg.accountId)/storage/kv/namespaces/$nsId/values/$escapedKey"
  try {
    $headers = @{ Authorization = "Bearer $($cfg.apiToken)" }
    $resp = Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $valueJson -ContentType "text/plain" -ErrorAction Stop
    if ($resp.success) {
      return [pscustomobject]@{ ok = $true; reason = "ok" }
    }
    return [pscustomobject]@{ ok = $false; reason = ($resp.errors | ConvertTo-Json -Compress) }
  } catch {
    return [pscustomobject]@{ ok = $false; reason = $_.Exception.Message }
  }
}

function Set-BridgePath {
  $env:PATH = "$NpmBin;$GitBashDir;$($env:PATH)"
}

function Ensure-Devspace {
  Set-BridgePath
  if (-not (Test-Path $DevspaceCmd)) {
    throw "DevSpace CLI not found at $DevspaceCmd. Install with: npm install -g @waishnav/devspace"
  }
}

function Assert-CloudflaredAuthenticode([string]$path) {
  $signature = Get-AuthenticodeSignature -LiteralPath $path
  $subject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { "" }
  if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "cloudflared Authenticode verification failed for ${path}: $($signature.Status)"
  }
  if ($subject -notmatch '(?i)Cloudflare, Inc\.') {
    throw "cloudflared signer is not Cloudflare, Inc.: $subject"
  }
}

function Ensure-Cloudflared {
  Ensure-Dirs
  if (Test-Path $CloudflaredPath) {
    Assert-CloudflaredAuthenticode $CloudflaredPath
    return
  }
  if (-not $InstallCloudflared) {
    throw "cloudflared not found at $CloudflaredPath. Re-run Start with -InstallCloudflared or install it manually."
  }
  $downloadPath = "$CloudflaredPath.$RunId.download"
  try {
    Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $downloadPath
    Assert-CloudflaredAuthenticode $downloadPath
    Move-Item -LiteralPath $downloadPath -Destination $CloudflaredPath
  } finally {
    if (Test-Path -LiteralPath $downloadPath) {
      Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Test-PathWithinRoot([string]$path, [string]$root) {
  $fullPath = [System.IO.Path]::GetFullPath($path).TrimEnd("\", "/")
  $fullRoot = [System.IO.Path]::GetFullPath($root).TrimEnd("\", "/")
  if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  return $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-AllowedRoots([string]$projectRoot, [string]$encodedRoots) {
  $candidates = @($projectRoot)
  if ($encodedRoots) {
    try {
      $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedRoots))
      $decoded = $json | ConvertFrom-Json
      $candidates = @()
      foreach ($decodedRoot in $decoded) { $candidates += $decodedRoot }
    } catch {
      throw "Invalid -AllowedRootsBase64 value: $($_.Exception.Message)"
    }
  }
  $resolved = @()
  $seen = @{}
  foreach ($candidate in $candidates) {
    $value = ([string]$candidate).Trim()
    if (-not $value) { continue }
    $item = Get-Item -LiteralPath (Resolve-Path -LiteralPath $value).Path
    if (-not $item.PSIsContainer) { throw "Allowed root is not a directory: $value" }
    if (-not $seen.ContainsKey($item.FullName)) {
      $seen[$item.FullName] = $true
      $resolved += $item.FullName
    }
  }
  if ($resolved.Count -eq 0) { throw "At least one allowed root is required." }
  if (@($resolved | Where-Object { Test-PathWithinRoot $projectRoot $_ }).Count -eq 0) {
    throw "ProjectRoot must be inside one of the allowed roots."
  }
  return @($resolved)
}

function Ensure-DevspaceConfig([string[]]$roots, [string]$publicBaseUrl, [string[]]$allowedHosts) {
  $configDir = Join-Path $HOME ".devspace"
  $configPath = Join-Path $configDir "config.json"
  $authPath = Join-Path $configDir "auth.json"
  New-Item -ItemType Directory -Force -Path $configDir | Out-Null

  $config = [ordered]@{
    host = "127.0.0.1"
    port = $Port
    allowedRoots = @($roots)
    publicBaseUrl = $publicBaseUrl
  }
  if ($allowedHosts -and $allowedHosts.Count -gt 0) {
    $config.allowedHosts = @($allowedHosts | Where-Object { $_ } | Select-Object -Unique)
  }
  Write-JsonFileAtomic $config $configPath

  if (-not (Test-Path $authPath)) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
      $bytes = New-Object byte[] 32
      $rng.GetBytes($bytes)
      $token = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
      Write-JsonFileAtomic ([ordered]@{ ownerToken = $token }) $authPath
    } finally {
      $rng.Dispose()
    }
  }
}

function Start-CloudflareTunnel {
  Ensure-Cloudflared
  $logPath = Join-Path $LogDir "cloudflared-$RunId.log"
  $tunnelArguments = 'tunnel --url "http://127.0.0.1:{0}" --no-autoupdate --no-prechecks --logfile "{1}" --loglevel info' -f $Port, $logPath

  $process = Start-Process -FilePath $CloudflaredPath `
    -ArgumentList $tunnelArguments `
    -PassThru -WindowStyle Hidden

  $deadline = (Get-Date).AddSeconds(60)
  $publicUrl = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $logPath) {
      $text = Get-Content -Raw -LiteralPath $logPath
      $match = [regex]::Match($text, "https://[-a-zA-Z0-9]+\.trycloudflare\.com")
      if ($match.Success) {
        $publicUrl = $match.Value
        break
      }
    }
    if ($process.HasExited) {
      throw "cloudflared exited before publishing a tunnel URL. See $logPath"
    }
  }
  if (-not $publicUrl) {
    throw "Timed out waiting for Cloudflare Quick Tunnel URL. See $logPath"
  }

  [pscustomobject]@{
    processId = $process.Id
    publicUrl = $publicUrl
    logPath = $logPath
  }
}

function Start-Devspace([string]$root, [string]$publicBaseUrl) {
  Ensure-Devspace
  $outPath = Join-Path $LogDir "devspace-$RunId.out.log"
  $errPath = Join-Path $LogDir "devspace-$RunId.err.log"

  $quote = { param([string]$value) "'" + $value.Replace("'", "''") + "'" }
  # Prefer User-level DEVSPACE_TOOL_MODE so mode survives bridge Restart.
  $toolMode = [Environment]::GetEnvironmentVariable("DEVSPACE_TOOL_MODE", "User")
  if (-not $toolMode) { $toolMode = $env:DEVSPACE_TOOL_MODE }
  $toolModeLine = if ($toolMode) {
    "`$env:DEVSPACE_TOOL_MODE = $(& $quote $toolMode)"
  } else {
    ""
  }
  $logShellCommands = [Environment]::GetEnvironmentVariable("DEVSPACE_LOG_SHELL_COMMANDS", "User")
  if (-not $logShellCommands) { $logShellCommands = $env:DEVSPACE_LOG_SHELL_COMMANDS }
  if (-not $logShellCommands) { $logShellCommands = "false" }
  $childScript = @"
`$env:PATH = $(& $quote "$NpmBin;$GitBashDir;") + `$env:PATH
`$env:DEVSPACE_PUBLIC_BASE_URL = $(& $quote $publicBaseUrl)
`$env:DEVSPACE_LOG_SHELL_COMMANDS = $(& $quote $logShellCommands)
$toolModeLine
Set-Location -LiteralPath $(& $quote $root)
& $(& $quote $DevspaceCmd) serve > $(& $quote $outPath) 2> $(& $quote $errPath)
"@
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
  $process = Start-Process -FilePath "powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded) `
    -WorkingDirectory $root `
    -PassThru -WindowStyle Hidden

  $deadline = (Get-Date).AddSeconds(15)
  $nodeProcess = $null
  while ((Get-Date) -lt $deadline) {
    $nodeProcess = Get-ManagedDevspaceProcesses $Port | Select-Object -First 1
    if ($nodeProcess) { break }
    if ($process.HasExited) {
      throw "DevSpace exited during startup. stdout=$outPath stderr=$errPath"
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not $nodeProcess) {
    throw "Timed out waiting for DevSpace to listen on 127.0.0.1:$Port. stdout=$outPath stderr=$errPath"
  }

  [pscustomobject]@{
    processId = if ($nodeProcess) { $nodeProcess.ProcessId } else { $process.Id }
    stdoutPath = $outPath
    stderrPath = $errPath
  }
}

function Stop-Bridge {
  $state = Get-State
  $port = if ($state -and $state.port) { [int]$state.port } else { $Port }
  $stopped = @()
  $skippedRecordedProcessIds = @()

  if ($state) {
    $recorded = @(
      [pscustomobject]@{ kind = "devspace"; processId = $state.devspaceProcessId; pattern = '*@waishnav*devspace*' },
      [pscustomobject]@{ kind = "tunnel"; processId = $state.tunnelProcessId; pattern = "*cloudflared*--url*127.0.0.1*$port*" }
    )
    foreach ($entry in $recorded) {
      if (-not $entry.processId) { continue }
      $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($entry.processId)" -ErrorAction SilentlyContinue
      $ownsConfiguredPort = $true
      if ($entry.kind -eq "devspace") {
        $ownsConfiguredPort = @(
          Get-ManagedDevspaceProcesses $port |
            Where-Object { $_.ProcessId -eq [int]$entry.processId }
        ).Count -gt 0
      }
      if ($processInfo -and $processInfo.CommandLine -like $entry.pattern -and $ownsConfiguredPort) {
        Stop-Process -Id $entry.processId -Force
        $stopped += $entry.processId
      } elseif ($processInfo) {
        $skippedRecordedProcessIds += $entry.processId
      }
    }
  }

  if ($DiscoverOrphans) {
    Get-ManagedDevspaceProcesses $port | ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force
      $stopped += $_.ProcessId
    }
    Get-CommandLineProcess "*cloudflared*--url*127.0.0.1*$port*" | ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force
      $stopped += $_.ProcessId
    }
  }

  if (Test-Path $StatePath) {
    Remove-Item -LiteralPath $StatePath -Force
  }

  Start-Sleep -Milliseconds 500
  [pscustomobject]@{
    action = "Stop"
    port = $port
    stoppedProcessIds = @($stopped | Select-Object -Unique)
    skippedRecordedProcessIds = @($skippedRecordedProcessIds | Select-Object -Unique)
    orphanDiscoveryUsed = [bool]$DiscoverOrphans
    remainingDevspace = @(Get-ManagedDevspaceProcesses $port)
    remainingTunnel = @(Get-CommandLineProcess "*cloudflared*--url*127.0.0.1*$port*")
    remainingPortOwners = @(Get-PortOwnerProcesses $port | Select-Object ProcessId, Name)
  }
}

function Get-BridgeStatus {
  $state = Get-State
  $port = if ($state -and $state.port) { [int]$state.port } else { $Port }
  [pscustomobject]@{
    action = "Status"
    statePath = $StatePath
    port = $port
    state = $state
    devspaceProcesses = @(Get-ManagedDevspaceProcesses $port)
    unrelatedPortOwners = @(Get-UnrelatedPortOwnerProcesses $port | Select-Object ProcessId, Name)
    tunnelProcesses = @(Get-CommandLineProcess "*cloudflared*--url*127.0.0.1*$port*")
    sharingWarning = "Status contains local paths, process metadata, allowed roots, and tunnel URLs. Redact it before sharing."
  }
}

function Test-PortListening([int]$port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect("127.0.0.1", $port, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(1000) -and $client.Connected) {
      return $true
    }
    return $false
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Get-HttpStatus([string]$url) {
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    return [int]$resp.StatusCode
  } catch {
    $r = $_.Exception.Response
    if ($r -and ($r.PSObject.Properties.Name -contains "StatusCode")) {
      try { return [int]$r.StatusCode } catch { return -1 }
    }
    return -1
  }
}

function Wait-EndpointPair(
  [string]$baseUrl,
  [int]$processId,
  [int]$timeoutSeconds = 60
) {
  $base = $baseUrl.TrimEnd("/")
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  $metadataStatus = -1
  $mcpStatus = -1
  do {
    if ($processId -gt 0 -and -not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
      return [pscustomobject]@{
        healthy = $false
        reason = "tunnel-process-exited"
        metadata = $metadataStatus
        mcp = $mcpStatus
      }
    }
    $metadataStatus = Get-HttpStatus "$base/.well-known/oauth-protected-resource/mcp"
    $mcpStatus = Get-HttpStatus "$base/mcp"
    if ($metadataStatus -eq 200 -and $mcpStatus -eq 401) {
      return [pscustomobject]@{
        healthy = $true
        reason = "ok"
        metadata = $metadataStatus
        mcp = $mcpStatus
      }
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)

  [pscustomobject]@{
    healthy = $false
    reason = "timeout"
    metadata = $metadataStatus
    mcp = $mcpStatus
  }
}

Ensure-Dirs

switch ($Action) {
  "Doctor" {
    Ensure-Devspace
    & $DevspaceCmd doctor

    $state = Get-State
    $port = if ($state -and $state.port) { [int]$state.port } else { $Port }
    $report = [ordered]@{
      action = "Doctor"
      cloudflaredInstalled = (Test-Path $CloudflaredPath)
      cloudflaredPath = $CloudflaredPath
      port = $port
      localPortListening = (Test-PortListening $port)
      publicBaseUrl = if ($state) { $state.publicBaseUrl } else { $null }
      sharingWarning = "Doctor output contains local paths and public endpoint metadata. Redact it before sharing."
    }
    if ($state -and $state.publicBaseUrl) {
      $base = ([string]$state.publicBaseUrl).TrimEnd("/")
      $report.oauthResourceStatus = Get-HttpStatus "$base/.well-known/oauth-protected-resource/mcp"
      $report.oauthResourceExpected = 200
      $report.mcpStatus = Get-HttpStatus "$base/mcp"
      $report.mcpExpected = 401
      if ($state.workerProxy -and $state.workerProxy.needsKvUpdate) {
        $report.needsKvUpdate = $true
        $report.kvUpdateError = $state.workerProxy.kvUpdateError
      }
    }
    Write-Json ([pscustomobject]$report)
    break
  }
  "Status" {
    Write-Json (Get-BridgeStatus)
    break
  }
  "Stop" {
    $DiscoverOrphans = $true
    Write-Json (Stop-Bridge)
    break
  }
  "Rotate" {
    # Panic button / re-key: lock out everyone who is or was connected.
    # 1) Stop the bridge so the devspace process drops all in-memory OAuth tokens.
    $previousDiscoverOrphans = $DiscoverOrphans
    $DiscoverOrphans = $true
    try {
      $stop = Stop-Bridge
    } finally {
      $DiscoverOrphans = $previousDiscoverOrphans
    }
    if (@($stop.remainingDevspace).Count -gt 0 -or @($stop.remainingTunnel).Count -gt 0 -or
        @($stop.remainingPortOwners).Count -gt 0 -or @($stop.skippedRecordedProcessIds).Count -gt 0) {
      throw "Rotate could not prove that every bridge and tunnel process stopped. OAuth material was not changed."
    }
    # 2) Delete persisted tokens so previously issued bearer/refresh tokens die.
    $devspaceStateDir = Join-Path $HOME ".devspace"
    $oauthStatePath = Join-Path $devspaceStateDir "oauth-state.json"
    $clearedPersistedTokens = Test-Path $oauthStatePath
    if ($clearedPersistedTokens) {
      Remove-Item -LiteralPath $oauthStatePath -Force
    }
    # 3) Mint a fresh 256-bit Owner password so the old one no longer authorizes.
    New-Item -ItemType Directory -Force -Path $devspaceStateDir | Out-Null
    $authPath = Join-Path $devspaceStateDir "auth.json"
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
      $bytes = New-Object byte[] 32
      $rng.GetBytes($bytes)
      $token = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
      Write-JsonFileAtomic ([ordered]@{ ownerToken = $token }) $authPath
    } finally {
      $rng.Dispose()
    }
    Write-Json ([pscustomobject]@{
      action = "Rotate"
      stoppedProcessIds = $stop.stoppedProcessIds
      clearedPersistedTokens = $clearedPersistedTokens
      ownerTokenPath = $authPath
      note = "New Owner password written (not shown). All previous authorizations are revoked. Use controller On, then re-authorize ChatGPT by reading the new token from auth.json into the approval form."
    })
    break
  }
  "Start" {
    $existingDevspace = @(Get-ManagedDevspaceProcesses $Port)
    $existingTunnel = @(Get-CommandLineProcess "*cloudflared*--url*127.0.0.1*$Port*")
    if ($existingDevspace.Count -gt 0 -or $existingTunnel.Count -gt 0 -or (Test-PortListening $Port)) {
      throw "Bridge processes or port $Port are already active. Use -Action Stop before starting a new instance."
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $resolvedAllowedRoots = @(Resolve-AllowedRoots $resolvedRoot $AllowedRootsBase64)
    Ensure-Devspace
    if ($Tunnel -in @("cloudflare", "cloudflare-worker")) {
      Ensure-Cloudflared
    }

    $proxyConfig = $null
    if ($Tunnel -eq "cloudflare-worker") {
      $proxyConfig = Get-WorkerProxyConfig
      if (-not $PublicBaseUrl -and $proxyConfig -and $proxyConfig.workerBaseUrl) {
        $PublicBaseUrl = $proxyConfig.workerBaseUrl
      }
      if (-not $PublicBaseUrl) {
        throw "-Tunnel cloudflare-worker requires -PublicBaseUrl or $WorkerProxyConfigPath with workerBaseUrl."
      }
      if (-not (Test-AbsoluteHttpsUrl $PublicBaseUrl)) {
        throw "-Tunnel cloudflare-worker requires an absolute HTTPS PublicBaseUrl without credentials, query, or fragment."
      }
      if (-not $proxyConfig -or -not $proxyConfig.kvNamespaceId) {
        throw "cloudflare-worker requires $WorkerProxyConfigPath with kvNamespaceId."
      }
      if ($RequireWorkerKv) {
        $cfPreflight = Get-CfApiConfig
        if (-not $cfPreflight -or -not $cfPreflight.accountId -or -not $cfPreflight.apiToken) {
          throw "Strict Worker KV mode requires a valid DPAPI or legacy Cloudflare API configuration."
        }
        if ($cfPreflight.kvNamespaceId -and
            -not ([string]$cfPreflight.kvNamespaceId).Equals([string]$proxyConfig.kvNamespaceId, [System.StringComparison]::OrdinalIgnoreCase)) {
          throw "Cloudflare credential metadata and worker-proxy.json reference different KV namespaces. Run set_cf_api_config.ps1 -Action Set again."
        }
        $cfPreflight = $null
      }
    }
    if ($Tunnel -eq "external" -and -not (Test-AbsoluteHttpsUrl $PublicBaseUrl)) {
      throw "-Tunnel external requires an absolute HTTPS PublicBaseUrl without credentials, query, or fragment."
    }

    $allowedHosts = @()
    $workerProxy = $null
    $tunnelInfo = $null
    $devspaceInfo = $null
    try {
      if ($Tunnel -eq "cloudflare") {
        $tunnelInfo = Start-CloudflareTunnel
        $publicBaseUrl = $tunnelInfo.publicUrl
      } elseif ($Tunnel -eq "cloudflare-worker") {
        $tunnelInfo = Start-CloudflareTunnel
        $publicBaseUrl = $PublicBaseUrl.TrimEnd("/")
        $allowedHosts = @(([uri]$publicBaseUrl).Host, ([uri]$tunnelInfo.publicUrl).Host)
        $workerProxy = [ordered]@{
          workerBaseUrl = $publicBaseUrl
          upstream = $tunnelInfo.publicUrl
          kvNamespaceId = $proxyConfig.kvNamespaceId
          kvKey = if ($proxyConfig.kvKey) { $proxyConfig.kvKey } else { "current" }
          updateMode = "manual-pending"
          needsKvUpdate = $true
        }
      } elseif ($Tunnel -eq "external") {
        $publicBaseUrl = $PublicBaseUrl.TrimEnd("/")
      } else {
        $publicBaseUrl = "http://127.0.0.1:$Port"
      }

      Ensure-DevspaceConfig -roots $resolvedAllowedRoots -publicBaseUrl $publicBaseUrl -allowedHosts $allowedHosts
      $devspaceInfo = Start-Devspace -root $resolvedRoot -publicBaseUrl $publicBaseUrl

      if ($tunnelInfo) {
        $quickTunnelHealth = Wait-EndpointPair `
          -baseUrl $tunnelInfo.publicUrl `
          -processId $tunnelInfo.processId `
          -timeoutSeconds 60
        if (-not $quickTunnelHealth.healthy) {
          throw "Quick Tunnel failed readiness before Worker KV update: reason=$($quickTunnelHealth.reason) metadata=$($quickTunnelHealth.metadata) mcp=$($quickTunnelHealth.mcp). Worker KV was not changed. See $($tunnelInfo.logPath)"
        }
      }

      if ($Tunnel -eq "cloudflare-worker" -and $workerProxy) {
        $kvValueJson = [ordered]@{
          upstream = $workerProxy.upstream
          publicBaseUrl = $workerProxy.workerBaseUrl
          updatedAt = (Get-Date).ToString("o")
          allowedHosts = $allowedHosts
        } | ConvertTo-Json -Depth 8 -Compress
        $kvResult = Update-WorkerKv -nsId $workerProxy.kvNamespaceId -key $workerProxy.kvKey -valueJson $kvValueJson
        if ($kvResult.ok) {
          $workerProxy.updateMode = "rest-api"
          $workerProxy.needsKvUpdate = $false
          $workerProxy.kvUpdatedAt = (Get-Date).ToString("o")
        } else {
          $workerProxy.kvUpdateError = $kvResult.reason
          if ($RequireWorkerKv) {
            throw "Cloudflare Worker KV refresh is required but failed: $($kvResult.reason)"
          }
        }
      }

      $state = [ordered]@{
        startedAt = (Get-Date).ToString("o")
        operationId = $RunId
        projectRoot = $resolvedRoot
        allowedRoots = $resolvedAllowedRoots
        tunnel = $Tunnel
        port = $Port
        publicBaseUrl = $publicBaseUrl
        mcpUrl = "$publicBaseUrl/mcp"
        devspaceProcessId = $devspaceInfo.processId
        tunnelProcessId = if ($tunnelInfo) { $tunnelInfo.processId } else { $null }
        workerProxy = $workerProxy
        logs = [ordered]@{
          devspaceStdout = $devspaceInfo.stdoutPath
          devspaceStderr = $devspaceInfo.stderrPath
          tunnel = if ($tunnelInfo) { $tunnelInfo.logPath } else { $null }
        }
      }
      Save-State $state
      Write-Json $state
    } catch {
      foreach ($processId in @(
        $(if ($devspaceInfo) { $devspaceInfo.processId }),
        $(if ($tunnelInfo) { $tunnelInfo.processId })
      )) {
        if ($processId) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
      }
      $savedState = Get-State
      if ($savedState -and $savedState.operationId -eq $RunId -and (Test-Path -LiteralPath $StatePath)) {
        Remove-Item -LiteralPath $StatePath -Force
      }
      throw
    }
    break
  }
}
