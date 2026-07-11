[CmdletBinding()]
param(
  [ValidateSet("Configure", "On", "Off", "Restart", "Reboot", "Status", "Doctor")]
  [string]$Action = "Status",

  [string]$ProjectRoot,

  [ValidateSet("none", "cloudflare", "external", "cloudflare-worker")]
  [string]$Tunnel,

  [int]$Port,

  [string]$PublicBaseUrl,

  [switch]$InstallCloudflared,

  [string]$StateDir = (Join-Path $env:LOCALAPPDATA "devspace-bridge"),

  [string]$BridgeScript,

  [ValidateRange(10, 300)]
  [int]$HealthTimeoutSec = 60
)

$ErrorActionPreference = "Stop"
if (-not $BridgeScript) {
  $BridgeScript = Join-Path $PSScriptRoot "local_bridge.ps1"
}
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
} catch {
  # Non-console hosts may not expose OutputEncoding.
}

$RequestedAction = $Action
$EffectiveAction = if ($Action -eq "Reboot") { "Restart" } else { $Action }
$OperationId = [Guid]::NewGuid().ToString("n")
$ProfilePath = Join-Path $StateDir "controller-profile.json"
$DesiredStatePath = Join-Path $StateDir "desired-state.json"
$RuntimeStatePath = Join-Path $StateDir "state.json"
$WorkerProxyConfigPath = Join-Path $StateDir "worker-proxy.json"
$CfApiConfigPath = Join-Path $StateDir "cf-api.json"
$CfApiProtectedConfigPath = Join-Path $StateDir "cf-api.protected.json"
$ResultPath = Join-Path $StateDir "controller-result.json"
$LogPath = Join-Path $StateDir "logs\controller.jsonl"
$PowerShellExe = (Get-Command powershell.exe -ErrorAction Stop).Source

function Ensure-ControllerDirs {
  New-Item -ItemType Directory -Force -Path $StateDir, (Split-Path -Parent $LogPath) | Out-Null
}

function Write-Json($obj) {
  [Console]::Out.WriteLine(($obj | ConvertTo-Json -Depth 10))
}

function Write-JsonFileAtomic($obj, [string]$path) {
  $json = $obj | ConvertTo-Json -Depth 10
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $tempPath = "$path.$([Guid]::NewGuid().ToString('n')).tmp"
  [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
  if (Test-Path -LiteralPath $path) {
    # .NET Framework's three-argument File.Replace rejects a null backup path on
    # some Windows PowerShell 5.1 hosts. A unique same-directory backup preserves
    # atomic replacement and is removed immediately after success.
    $backupPath = "$path.$([Guid]::NewGuid().ToString('n')).bak"
    try {
      [System.IO.File]::Replace($tempPath, $path, $backupPath)
    } finally {
      if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
      }
    }
  } else {
    [System.IO.File]::Move($tempPath, $path)
  }
}

function Get-JsonFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json
}

function Write-ControllerEvent([string]$stage, [string]$status, [string]$message, $data = $null) {
  $entry = [ordered]@{
    timestamp = (Get-Date).ToString("o")
    operationId = $OperationId
    requestedAction = $RequestedAction
    effectiveAction = $EffectiveAction
    stage = $stage
    status = $status
    message = $message
  }
  if ($null -ne $data) { $entry.data = $data }
  $line = ($entry | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::AppendAllText($LogPath, $line, $utf8NoBom)
}

function Write-ControllerResult([string]$status, [string]$stage, [string]$message, $data = $null) {
  $result = [ordered]@{
    operationId = $OperationId
    requestedAction = $RequestedAction
    effectiveAction = $EffectiveAction
    status = $status
    stage = $stage
    message = $message
    completedAt = (Get-Date).ToString("o")
    resultPath = $ResultPath
    logPath = $LogPath
  }
  if ($null -ne $data) { $result.data = $data }
  Write-JsonFileAtomic $result $ResultPath
  Write-Json $result
}

function Get-CfApiMode {
  if (Test-Path -LiteralPath $CfApiProtectedConfigPath) { return "dpapi" }
  if (Test-Path -LiteralPath $CfApiConfigPath) { return "plaintext-legacy" }
  return "missing"
}

function Test-AbsoluteHttpsUrl([string]$url) {
  if (-not $url) { return $false }
  $parsed = $null
  if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsed)) { return $false }
  return ($parsed.Scheme -eq "https" -and -not [string]::IsNullOrWhiteSpace($parsed.Host))
}

function Set-DesiredState([string]$state, [string]$reason) {
  Write-JsonFileAtomic ([ordered]@{
    state = $state
    reason = $reason
    operationId = $OperationId
    updatedAt = (Get-Date).ToString("o")
  }) $DesiredStatePath
}

function Test-PortListening([int]$portNumber) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect("127.0.0.1", $portNumber, $null, $null)
    return ($iar.AsyncWaitHandle.WaitOne(1000) -and $client.Connected)
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Get-HttpStatus([string]$url) {
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    return [int]$resp.StatusCode
  } catch {
    $response = $_.Exception.Response
    if ($response -and ($response.PSObject.Properties.Name -contains "StatusCode")) {
      try { return [int]$response.StatusCode } catch { return -1 }
    }
    return -1
  }
}

function Test-EndpointPair([string]$name, [string]$baseUrl) {
  if (-not $baseUrl) {
    return [ordered]@{ name = $name; baseUrl = $null; metadata = -1; mcp = -1; healthy = $false }
  }
  $base = $baseUrl.TrimEnd("/")
  $metadataStatus = Get-HttpStatus "$base/.well-known/oauth-protected-resource/mcp"
  $mcpStatus = Get-HttpStatus "$base/mcp"
  [ordered]@{
    name = $name
    baseUrl = $base
    metadata = $metadataStatus
    metadataExpected = 200
    mcp = $mcpStatus
    mcpExpected = 401
    healthy = ($metadataStatus -eq 200 -and $mcpStatus -eq 401)
  }
}

function Test-BridgeHealth($runtimeState) {
  if (-not $runtimeState) {
    return [ordered]@{ healthy = $false; reason = "runtime-state-missing"; checks = @() }
  }
  $runtimePort = [int]$runtimeState.port
  $checks = @()
  $checks += Test-EndpointPair "local" "http://127.0.0.1:$runtimePort"
  if ($runtimeState.workerProxy -and $runtimeState.workerProxy.upstream) {
    $checks += Test-EndpointPair "quick-tunnel" ([string]$runtimeState.workerProxy.upstream)
  }
  $publicBase = [string]$runtimeState.publicBaseUrl
  if ($publicBase -and $publicBase -ne "http://127.0.0.1:$runtimePort") {
    $checks += Test-EndpointPair "stable-public" $publicBase
  }
  $portListening = Test-PortListening $runtimePort
  $allEndpointsHealthy = (@($checks | Where-Object { -not $_.healthy }).Count -eq 0)
  [ordered]@{
    healthy = ($portListening -and $allEndpointsHealthy)
    localPortListening = $portListening
    port = $runtimePort
    checks = $checks
  }
}

function Wait-ForBridgeHealth($runtimeState, [int]$timeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  $last = $null
  do {
    $last = Test-BridgeHealth $runtimeState
    if ($last.healthy) { return $last }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  return $last
}

function Get-ControllerStatus {
  $profile = Get-JsonFile $ProfilePath
  $desired = Get-JsonFile $DesiredStatePath
  $runtime = Get-JsonFile $RuntimeStatePath
  [ordered]@{
    action = "Status"
    profilePath = $ProfilePath
    profile = $profile
    desiredStatePath = $DesiredStatePath
    desiredState = $desired
    runtimeStatePath = $RuntimeStatePath
    runtimeState = $runtime
    cfApiMode = Get-CfApiMode
    lastResult = Get-JsonFile $ResultPath
    sharingWarning = "Status contains local paths, process metadata, and tunnel URLs. Redact it before sharing."
  }
}

function Assert-ProfileReady($profile) {
  if (-not $profile) { throw "Controller profile is missing. Run -Action Configure first." }
  if (-not (Test-Path -LiteralPath $BridgeScript)) { throw "Bridge runtime script not found: $BridgeScript" }
  if (-not $profile.projectRoot -or -not (Test-Path -LiteralPath ([string]$profile.projectRoot))) {
    throw "Configured project root is missing: $($profile.projectRoot)"
  }
  if ($profile.tunnel -eq "cloudflare-worker") {
    $proxy = Get-JsonFile $WorkerProxyConfigPath
    if (-not $proxy -or -not $proxy.workerBaseUrl -or -not $proxy.kvNamespaceId) {
      throw "cloudflare-worker mode requires $WorkerProxyConfigPath with workerBaseUrl and kvNamespaceId."
    }
    $profileBase = ([string]$profile.publicBaseUrl).TrimEnd("/")
    $proxyBase = ([string]$proxy.workerBaseUrl).TrimEnd("/")
    if (-not (Test-AbsoluteHttpsUrl $profileBase)) {
      throw "cloudflare-worker publicBaseUrl must be an absolute HTTPS URL with a host."
    }
    if (-not $profileBase.Equals($proxyBase, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Controller profile publicBaseUrl does not match worker-proxy.json; refusing to change the stable ChatGPT app URL."
    }
    if ((Get-CfApiMode) -eq "missing") {
      throw "Automatic restart requires a Cloudflare KV credential. Run set_cf_api_config.ps1 -Action Set first."
    }
  }
}

function Test-RuntimeMatchesProfile($runtime, $profile) {
  if (-not $runtime -or -not $profile) { return $false }
  if ($runtime.projectRoot -ne $profile.projectRoot) { return $false }
  if ($runtime.tunnel -ne $profile.tunnel) { return $false }
  if ([int]$runtime.port -ne [int]$profile.port) { return $false }
  if ($profile.publicBaseUrl -and (([string]$runtime.publicBaseUrl).TrimEnd("/") -ne ([string]$profile.publicBaseUrl).TrimEnd("/"))) {
    return $false
  }
  return $true
}

function Invoke-BridgeRuntime([string]$runtimeAction, $profile = $null) {
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $BridgeScript,
    "-Action", $runtimeAction,
    "-StateDir", $StateDir
  )
  if ($runtimeAction -eq "Start") {
    $arguments += @(
      "-ProjectRoot", [string]$profile.projectRoot,
      "-Tunnel", [string]$profile.tunnel,
      "-Port", [string]$profile.port,
      "-OperationId", $OperationId
    )
    if ($profile.publicBaseUrl) { $arguments += @("-PublicBaseUrl", [string]$profile.publicBaseUrl) }
    if ([bool]$profile.installCloudflared) { $arguments += "-InstallCloudflared" }
    if ($profile.tunnel -eq "cloudflare-worker") { $arguments += "-RequireWorkerKv" }
  } elseif ($runtimeAction -eq "Stop" -and $profile -and $profile.port) {
    $arguments += @("-Port", [string]$profile.port)
  }
  $output = & $PowerShellExe @arguments 2>&1
  $exitCode = $LASTEXITCODE
  $message = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
  if ($exitCode -ne 0) {
    if (-not $message) { $message = "Bridge runtime action $runtimeAction failed with exit code $exitCode." }
    throw $message
  }
  if (-not $message) { return $null }
  try { return ($message | ConvertFrom-Json) } catch { return $message }
}

function Stop-AndVerify($profile) {
  $stopResult = Invoke-BridgeRuntime "Stop" $profile
  $stopPort = if ($profile -and $profile.port) { [int]$profile.port } else { 7676 }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline -and (Test-PortListening $stopPort)) {
    Start-Sleep -Milliseconds 500
  }
  if (Test-PortListening $stopPort) {
    throw "Bridge Stop did not release local port $stopPort."
  }
  if ($stopResult -and $stopResult.skippedRecordedProcessIds -and @($stopResult.skippedRecordedProcessIds).Count -gt 0) {
    throw "Bridge Stop skipped recorded PIDs after command-line identity validation."
  }
  if ($stopResult -and $stopResult.remainingTunnel -and @($stopResult.remainingTunnel).Count -gt 0) {
    throw "Bridge Stop left a tunnel process on port $stopPort."
  }
  if ($stopResult -and $stopResult.remainingDevspace -and @($stopResult.remainingDevspace).Count -gt 0) {
    throw "Bridge Stop left a DevSpace process. This release supports one managed bridge instance per Windows user."
  }
  return $stopResult
}

function Start-AndVerify($profile) {
  Assert-ProfileReady $profile
  Write-ControllerEvent "start" "running" "Starting bridge runtime."
  try {
    $null = Invoke-BridgeRuntime "Start" $profile
  } catch {
    throw
  }
  $runtime = Get-JsonFile $RuntimeStatePath
  if (-not $runtime) { throw "Bridge runtime did not write state.json." }
  if ($runtime.operationId -ne $OperationId) {
    try { $null = Stop-AndVerify $profile } catch { }
    throw "Runtime state operationId does not match the controller operation."
  }
  if (-not (Test-RuntimeMatchesProfile $runtime $profile)) {
    try { $null = Stop-AndVerify $profile } catch { }
    throw "Runtime state does not match the persisted controller profile."
  }
  if ($profile.tunnel -eq "cloudflare-worker") {
    $worker = $runtime.workerProxy
    if (-not $worker -or $worker.updateMode -ne "rest-api" -or $worker.needsKvUpdate -or $worker.kvUpdateError -or -not $worker.kvUpdatedAt) {
      try { $null = Stop-AndVerify $profile } catch { }
      throw "Runtime did not record a successful strict Worker KV refresh."
    }
  }
  Write-ControllerEvent "verify" "running" "Waiting for local, tunnel, and stable Worker health."
  $health = Wait-ForBridgeHealth $runtime $HealthTimeoutSec
  if (-not $health.healthy) {
    Write-ControllerEvent "verify" "failed" "Health verification failed; cleaning up the partial runtime." $health
    try { $null = Stop-AndVerify $profile } catch { }
    throw "Bridge failed health verification after $HealthTimeoutSec seconds."
  }
  Write-ControllerEvent "verify" "passed" "Bridge health reached the expected 200/401 contract." $health
  return [ordered]@{ runtime = $runtime; health = $health }
}

function Acquire-ControllerMutex {
  $mutex = [System.Threading.Mutex]::new($false, "Global\CodexChatGPTBridge.Controller")
  $acquired = $false
  try {
    $acquired = $mutex.WaitOne(0)
  } catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
  }
  if (-not $acquired) {
    $mutex.Dispose()
    throw "Another bridge controller operation is already running."
  }
  return $mutex
}

$mutexHandle = $null
$needsLock = @("Configure", "On", "Off", "Restart") -contains $EffectiveAction
$exitCode = 0

try {
  if ($needsLock) {
    Ensure-ControllerDirs
    $mutexHandle = Acquire-ControllerMutex
    Write-ControllerEvent "begin" "running" "Controller operation started."
  }

  switch ($EffectiveAction) {
    "Status" {
      Write-Json (Get-ControllerStatus)
      break
    }

    "Doctor" {
      $runtime = Get-JsonFile $RuntimeStatePath
      $health = Test-BridgeHealth $runtime
      $profile = Get-JsonFile $ProfilePath
      $readinessIssues = @()
      if (-not $profile) { $readinessIssues += "controller-profile-missing" }
      if ($profile -and $profile.tunnel -eq "cloudflare-worker" -and (Get-CfApiMode) -eq "missing") {
        $readinessIssues += "cloudflare-kv-credential-missing"
      }
      if ($runtime -and $runtime.workerProxy -and ($runtime.workerProxy.needsKvUpdate -or $runtime.workerProxy.kvUpdateError)) {
        $readinessIssues += "runtime-worker-kv-not-confirmed"
      }
      $report = [ordered]@{
        action = "Doctor"
        runtimeHealthy = $health.healthy
        health = $health
        restartReady = ($readinessIssues.Count -eq 0)
        readinessIssues = $readinessIssues
        cfApiMode = Get-CfApiMode
        profileConfigured = (Test-Path -LiteralPath $ProfilePath)
        desiredState = Get-JsonFile $DesiredStatePath
        sharingWarning = "Doctor output contains local paths and tunnel URLs. Redact it before sharing."
      }
      Write-Json $report
      if (-not $health.healthy) { $exitCode = 1 }
      break
    }

    "Configure" {
      $runtime = Get-JsonFile $RuntimeStatePath
      $effectiveRoot = if ($ProjectRoot) { $ProjectRoot } elseif ($runtime) { [string]$runtime.projectRoot } else { $null }
      if (-not $effectiveRoot) { throw "-ProjectRoot is required when there is no running bridge state to import." }
      $resolvedRoot = (Resolve-Path -LiteralPath $effectiveRoot).Path
      $effectiveTunnel = if ($PSBoundParameters.ContainsKey("Tunnel")) { $Tunnel } elseif ($runtime) { [string]$runtime.tunnel } else { "cloudflare-worker" }
      $effectivePort = if ($PSBoundParameters.ContainsKey("Port")) { $Port } elseif ($runtime -and $runtime.port) { [int]$runtime.port } else { 7676 }
      $effectivePublicBase = if ($PublicBaseUrl) { $PublicBaseUrl.TrimEnd("/") } elseif ($runtime -and $runtime.publicBaseUrl) { ([string]$runtime.publicBaseUrl).TrimEnd("/") } else { $null }
      if ($effectiveTunnel -eq "cloudflare-worker" -and -not $effectivePublicBase) {
        $proxy = Get-JsonFile $WorkerProxyConfigPath
        if ($proxy -and $proxy.workerBaseUrl) { $effectivePublicBase = ([string]$proxy.workerBaseUrl).TrimEnd("/") }
      }
      if ($effectiveTunnel -eq "cloudflare-worker" -and -not (Test-AbsoluteHttpsUrl $effectivePublicBase)) {
        throw "cloudflare-worker requires -PublicBaseUrl as an absolute HTTPS URL with a host."
      }
      $profile = [ordered]@{
        schemaVersion = 1
        projectRoot = $resolvedRoot
        tunnel = $effectiveTunnel
        port = $effectivePort
        publicBaseUrl = $effectivePublicBase
        installCloudflared = [bool]$InstallCloudflared
        configuredAt = (Get-Date).ToString("o")
      }
      Write-JsonFileAtomic $profile $ProfilePath
      if ($effectiveTunnel -eq "cloudflare-worker") {
        $existingProxy = Get-JsonFile $WorkerProxyConfigPath
        if ($existingProxy -and $existingProxy.kvNamespaceId) {
          Write-JsonFileAtomic ([ordered]@{
            workerBaseUrl = $effectivePublicBase
            kvNamespaceId = [string]$existingProxy.kvNamespaceId
            kvKey = if ($existingProxy.kvKey) { [string]$existingProxy.kvKey } else { "current" }
            updatedAt = (Get-Date).ToString("o")
          }) $WorkerProxyConfigPath
        }
      }
      if (-not (Test-Path -LiteralPath $DesiredStatePath)) {
        $initialState = "stopped"
        $initialReason = "controller-configured-unverified"
        if ($runtime -and (Test-RuntimeMatchesProfile $runtime $profile)) {
          $initialHealth = Test-BridgeHealth $runtime
          if ($initialHealth.healthy) {
            $initialState = "running"
            $initialReason = "controller-imported-healthy-runtime"
          }
        }
        Set-DesiredState $initialState $initialReason
      }
      Write-ControllerEvent "configure" "passed" "Controller profile saved." ([ordered]@{ profilePath = $ProfilePath; projectRoot = $resolvedRoot; tunnel = $effectiveTunnel; port = $effectivePort })
      Write-ControllerResult "success" "configure" "Controller profile is ready." ([ordered]@{ profilePath = $ProfilePath; desiredState = Get-JsonFile $DesiredStatePath })
      break
    }

    "Off" {
      $profile = Get-JsonFile $ProfilePath
      Set-DesiredState "stopped" "operator-off"
      Write-ControllerEvent "stop" "running" "Stopping bridge runtime and preserving the controller profile."
      $stopResult = Stop-AndVerify $profile
      Write-ControllerEvent "stop" "passed" "Bridge runtime stopped."
      Write-ControllerResult "success" "off" "Bridge is intentionally off; Restart/Reboot will not reopen it until On is used." $stopResult
      break
    }

    "On" {
      $profile = Get-JsonFile $ProfilePath
      Assert-ProfileReady $profile
      $runtime = Get-JsonFile $RuntimeStatePath
      if ($runtime) {
        if (-not (Test-RuntimeMatchesProfile $runtime $profile)) {
          throw "An existing runtime does not match the configured profile. Use Restart after reviewing Status."
        }
        $currentHealth = Test-BridgeHealth $runtime
        if ($currentHealth.healthy) {
          Set-DesiredState "running" "operator-on-reused"
          Write-ControllerEvent "on" "passed" "Existing matching runtime is already healthy; reusing it." $currentHealth
          Write-ControllerResult "success" "on" "Bridge was already running and healthy; no restart was performed." ([ordered]@{ runtime = $runtime; health = $currentHealth; reused = $true })
          break
        }
        Write-ControllerEvent "stop" "running" "Existing matching runtime is unhealthy; stopping it before recovery."
        $null = Stop-AndVerify $profile
      }
      Set-DesiredState "running" "operator-on"
      $result = Start-AndVerify $profile
      Write-ControllerResult "success" "on" "Bridge is running and healthy." $result
      break
    }

    "Restart" {
      $profile = Get-JsonFile $ProfilePath
      $desired = Get-JsonFile $DesiredStatePath
      if (-not $desired -or $desired.state -ne "running") {
        throw "Bridge is intentionally off. Use -Action On before Restart/Reboot."
      }
      Assert-ProfileReady $profile
      Write-ControllerEvent "stop" "running" "Stopping the previous runtime as part of one Restart transaction."
      $stopResult = Stop-AndVerify $profile
      Write-ControllerEvent "stop" "passed" "Previous runtime stopped."
      $result = Start-AndVerify $profile
      Write-ControllerResult "success" "restart" "Restart/Reboot completed as one verified transaction." $result
      break
    }
  }
} catch {
  $exitCode = 1
  $message = $_.Exception.Message
  if ($needsLock) {
    Write-ControllerEvent "failed" "failed" $message
    Write-ControllerResult "failed" "failed" $message
  } else {
    Write-Json ([ordered]@{
      requestedAction = $RequestedAction
      effectiveAction = $EffectiveAction
      status = "failed"
      message = $message
    })
  }
} finally {
  if ($mutexHandle) {
    try { $mutexHandle.ReleaseMutex() } catch { }
    $mutexHandle.Dispose()
  }
}

if ($exitCode -ne 0) { exit $exitCode }
