[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion -lt [Version]"5.1") {
  throw "Run this validation with Windows PowerShell 5.1 (powershell.exe), not pwsh."
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$skillRoot = Join-Path $repoRoot "skills\codex-chatgpt-bridge"
$scripts = @(
  (Join-Path $repoRoot "install.ps1"),
  (Join-Path $PSScriptRoot "static_validation.ps1"),
  (Join-Path $skillRoot "scripts\local_bridge.ps1"),
  (Join-Path $skillRoot "scripts\bridge_controller.ps1"),
  (Join-Path $skillRoot "scripts\restart_task.ps1"),
  (Join-Path $skillRoot "scripts\set_cf_api_config.ps1")
)
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powerShellExe)) { throw "Windows PowerShell 5.1 not found: $powerShellExe" }
$controller = Join-Path $skillRoot "scripts\bridge_controller.ps1"
$bridgeScript = Join-Path $skillRoot "scripts\local_bridge.ps1"
$taskScript = Join-Path $skillRoot "scripts\restart_task.ps1"
$cfConfigScript = Join-Path $skillRoot "scripts\set_cf_api_config.ps1"
$installScript = Join-Path $repoRoot "install.ps1"
$stateDir = Join-Path $env:TEMP ("codex-chatgpt-bridge-test-" + [Guid]::NewGuid().ToString("n"))
$taskName = "CodexChatGPTBridge-Test-" + [Guid]::NewGuid().ToString("n")
$listenerProcess = $null
$spoofedDevspaceProcess = $null

function Test-LocalPortListening([int]$Port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    return ($iar.AsyncWaitHandle.WaitOne(500) -and $client.Connected)
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Invoke-ChildPowerShell([string[]]$Arguments, [bool]$ExpectSuccess = $true) {
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    # Windows PowerShell promotes native stderr to ErrorRecord objects. Keep collecting
    # them so expected child failures can be asserted from their exit code and JSON result.
    $ErrorActionPreference = "Continue"
    $output = & $powerShellExe -NoProfile -ExecutionPolicy Bypass @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($ExpectSuccess -and $exitCode -ne 0) {
    throw "Child PowerShell failed with exit code ${exitCode}:`n$($output -join [Environment]::NewLine)"
  }
  if (-not $ExpectSuccess -and $exitCode -eq 0) {
    throw "Child PowerShell unexpectedly succeeded:`n$($output -join [Environment]::NewLine)"
  }
  [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

try {
  foreach ($scriptPath in $scripts) {
    if (-not (Test-Path -LiteralPath $scriptPath)) {
      throw "Expected script is missing: $scriptPath"
    }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
      $scriptPath,
      [ref]$tokens,
      [ref]$errors
    )
    if ($errors.Count -gt 0) {
      $details = $errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }
      throw "PowerShell parse errors in ${scriptPath}:`n$($details -join [Environment]::NewLine)"
    }
  }

  $bridgeSource = [System.IO.File]::ReadAllText($bridgeScript)
  if ($bridgeSource -notmatch '--no-prechecks') {
    throw "cloudflared startup does not bypass the redundant built-in prechecks."
  }
  $quickReadinessIndex = $bridgeSource.IndexOf('$quickTunnelHealth = Wait-EndpointPair', [System.StringComparison]::Ordinal)
  $kvUpdateIndex = $bridgeSource.IndexOf('$kvResult = Update-WorkerKv', [System.StringComparison]::Ordinal)
  if ($quickReadinessIndex -lt 0 -or $kvUpdateIndex -lt 0 -or $quickReadinessIndex -ge $kvUpdateIndex) {
    throw "Worker KV can be updated before the new Quick Tunnel passes readiness."
  }
  if ($bridgeSource -notmatch 'Worker KV was not changed') {
    throw "Quick Tunnel readiness failure does not explicitly preserve Worker KV."
  }

  Add-Type -AssemblyName System.Security
  $dpapiPlain = New-Object byte[] 32
  $testRng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $testRng.GetBytes($dpapiPlain)
  } finally {
    $testRng.Dispose()
  }
  $dpapiCipher = [System.Security.Cryptography.ProtectedData]::Protect(
    $dpapiPlain,
    $null,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
  )
  $dpapiRoundTrip = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $dpapiCipher,
    $null,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
  )
  $dpapiMatches = ($dpapiPlain.Length -eq $dpapiRoundTrip.Length)
  if ($dpapiMatches) {
    for ($index = 0; $index -lt $dpapiPlain.Length; $index++) {
      if ($dpapiPlain[$index] -ne $dpapiRoundTrip[$index]) {
        $dpapiMatches = $false
        break
      }
    }
  }
  [Array]::Clear($dpapiPlain, 0, $dpapiPlain.Length)
  [Array]::Clear($dpapiRoundTrip, 0, $dpapiRoundTrip.Length)
  if (-not $dpapiMatches) { throw "Windows DPAPI round-trip validation failed." }

  $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $listenerPort = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
  $probe.Stop()
  $listenerScript = @"
`$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $listenerPort)
`$listener.Start()
try {
  while (`$true) { Start-Sleep -Seconds 1 }
} finally {
  `$listener.Stop()
}
"@
  $listenerEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($listenerScript))
  $listenerProcess = Start-Process -FilePath $powerShellExe `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $listenerEncoded) `
    -PassThru -WindowStyle Hidden
  $listenerDeadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $listenerDeadline -and -not (Test-LocalPortListening $listenerPort)) {
    Start-Sleep -Milliseconds 100
  }
  if (-not (Test-LocalPortListening $listenerPort)) {
    throw "Test listener failed to bind to port $listenerPort."
  }
  $orphanStopState = Join-Path $stateDir "orphan-stop"
  $scopedStop = Invoke-ChildPowerShell @(
    "-File", $bridgeScript,
    "-Action", "Stop",
    "-Port", [string]$listenerPort,
    "-StateDir", $orphanStopState
  )
  $scopedStopJson = ($scopedStop.Output -join [Environment]::NewLine) | ConvertFrom-Json
  if ($listenerProcess.HasExited -or -not (Test-LocalPortListening $listenerPort)) {
    throw "Low-level Stop killed an unrelated process that owned the requested port."
  }
  if (@($scopedStopJson.remainingDevspace).Count -ne 0) {
    throw "Low-level Stop misclassified an unrelated listener as DevSpace."
  }
  if (-not (@($scopedStopJson.remainingPortOwners).ProcessId -contains $listenerProcess.Id)) {
    throw "Low-level Stop did not report the unrelated remaining port owner."
  }
  Stop-Process -Id $listenerProcess.Id -Force
  $listenerProcess = $null

  $spoofedScript = @"
`$marker = '@waishnav\devspace'
while (`$true) { Start-Sleep -Seconds 1 }
"@
  $spoofedEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($spoofedScript))
  $spoofedDevspaceProcess = Start-Process -FilePath $powerShellExe `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $spoofedEncoded) `
    -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 250
  $stalePidState = Join-Path $stateDir "stale-pid"
  New-Item -ItemType Directory -Force -Path $stalePidState | Out-Null
  $stalePidPort = $listenerPort
  [System.IO.File]::WriteAllText(
    (Join-Path $stalePidState "state.json"),
    (@{ port = $stalePidPort; devspaceProcessId = $spoofedDevspaceProcess.Id } | ConvertTo-Json),
    (New-Object System.Text.UTF8Encoding $false)
  )
  $stalePidStop = Invoke-ChildPowerShell @(
    "-File", $bridgeScript,
    "-Action", "Stop",
    "-Port", [string]$stalePidPort,
    "-StateDir", $stalePidState
  )
  $stalePidStopJson = ($stalePidStop.Output -join [Environment]::NewLine) | ConvertFrom-Json
  if ($spoofedDevspaceProcess.HasExited) {
    throw "Low-level Stop killed a stale recorded PID that did not own the configured port."
  }
  if (-not (@($stalePidStopJson.skippedRecordedProcessIds) -contains $spoofedDevspaceProcess.Id)) {
    throw "Low-level Stop did not report the stale recorded PID as skipped."
  }
  Stop-Process -Id $spoofedDevspaceProcess.Id -Force
  $spoofedDevspaceProcess = $null

  $testCodexHome = Join-Path $stateDir "codex-home"
  $null = Invoke-ChildPowerShell -Arguments @(
    "-File", $installScript,
    "-CodexHome", $testCodexHome
  )
  $installedSkill = Join-Path $testCodexHome "skills\codex-chatgpt-bridge"
  if (-not (Test-Path -LiteralPath (Join-Path $installedSkill "SKILL.md"))) {
    throw "Installer did not copy the skill into the test Codex home."
  }
  $markerPath = Join-Path $installedSkill "test-existing-install-marker.txt"
  [System.IO.File]::WriteAllText($markerPath, "preserve-me", (New-Object System.Text.UTF8Encoding $false))
  $null = Invoke-ChildPowerShell -Arguments @(
    "-File", $installScript,
    "-CodexHome", $testCodexHome
  )
  $backupRoot = Join-Path $testCodexHome "skills"
  $backups = @(Get-ChildItem -LiteralPath $backupRoot -Directory | Where-Object { $_.Name -like "codex-chatgpt-bridge.backup-*" })
  if ($backups.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $backups[0].FullName "test-existing-install-marker.txt"))) {
    throw "Installer did not preserve the existing skill in one timestamped backup."
  }

  $secondAllowedRoot = Join-Path $stateDir "second-allowed-root"
  New-Item -ItemType Directory -Force -Path $secondAllowedRoot | Out-Null
  $configure = Invoke-ChildPowerShell @(
    "-File", $controller,
    "-Action", "Configure",
    "-ProjectRoot", $repoRoot,
    "-AllowedRoots", "$repoRoot;$secondAllowedRoot",
    "-Tunnel", "none",
    "-StateDir", $stateDir,
    "-BridgeScript", $bridgeScript
  )
  $configureJson = ($configure.Output -join [Environment]::NewLine) | ConvertFrom-Json
  if ($configureJson.status -ne "success") { throw "Configure did not report success." }

  $status = Invoke-ChildPowerShell @(
    "-File", $controller,
    "-Action", "Status",
    "-StateDir", $stateDir,
    "-BridgeScript", $bridgeScript
  )
  $statusJson = ($status.Output -join [Environment]::NewLine) | ConvertFrom-Json
  if ($statusJson.profile.tunnel -ne "none") { throw "Status did not preserve the test profile." }
  if ([int]$statusJson.profile.schemaVersion -ne 2) { throw "Configure did not write the multi-root profile schema." }
  if (@($statusJson.profile.allowedRoots).Count -ne 2) { throw "Configure did not preserve both allowed roots." }
  if (-not (@($statusJson.profile.allowedRoots) -contains $repoRoot) -or -not (@($statusJson.profile.allowedRoots) -contains $secondAllowedRoot)) {
    throw "Status did not return the configured allowed roots."
  }
  if ($statusJson.desiredState.state -ne "stopped") { throw "Configure must default to intentionally stopped." }

  $cfStatus = Invoke-ChildPowerShell @(
    "-File", $cfConfigScript,
    "-Action", "Status",
    "-StateDir", $stateDir
  )
  $cfStatusJson = ($cfStatus.Output -join [Environment]::NewLine) | ConvertFrom-Json
  if ($cfStatusJson.effectiveMode -ne "missing") { throw "Fresh test state unexpectedly contains a Cloudflare credential." }

  $unsafeUrlStateDir = Join-Path $stateDir "unsafe-public-url"
  $unsafeUrlConfigure = Invoke-ChildPowerShell -Arguments @(
    "-File", $controller,
    "-Action", "Configure",
    "-ProjectRoot", $repoRoot,
    "-Tunnel", "cloudflare-worker",
    "-PublicBaseUrl", "https://user:password@bridge.example.workers.dev",
    "-StateDir", $unsafeUrlStateDir,
    "-BridgeScript", $bridgeScript
  ) -ExpectSuccess $false
  $unsafeUrlResult = [System.IO.File]::ReadAllText((Join-Path $unsafeUrlStateDir "controller-result.json"), (New-Object System.Text.UTF8Encoding $false)) | ConvertFrom-Json
  if ($unsafeUrlResult.message -notmatch "without credentials") {
    throw "Controller did not reject a public URL containing credentials.`n$($unsafeUrlConfigure.Output -join [Environment]::NewLine)"
  }

  $insecureExternalStateDir = Join-Path $stateDir "insecure-external-url"
  $insecureExternalConfigure = Invoke-ChildPowerShell -Arguments @(
    "-File", $controller,
    "-Action", "Configure",
    "-ProjectRoot", $repoRoot,
    "-Tunnel", "external",
    "-PublicBaseUrl", "http://bridge.example.test",
    "-StateDir", $insecureExternalStateDir,
    "-BridgeScript", $bridgeScript
  ) -ExpectSuccess $false
  $insecureExternalResult = [System.IO.File]::ReadAllText((Join-Path $insecureExternalStateDir "controller-result.json"), (New-Object System.Text.UTF8Encoding $false)) | ConvertFrom-Json
  if ($insecureExternalResult.message -notmatch "absolute HTTPS") {
    throw "Controller did not reject an insecure external public URL.`n$($insecureExternalConfigure.Output -join [Environment]::NewLine)"
  }

  $invalidPort = Invoke-ChildPowerShell -Arguments @(
    "-File", $controller,
    "-Action", "Configure",
    "-ProjectRoot", $repoRoot,
    "-Tunnel", "none",
    "-Port", "70000",
    "-StateDir", (Join-Path $stateDir "invalid-port"),
    "-BridgeScript", $bridgeScript
  ) -ExpectSuccess $false
  if (($invalidPort.Output -join [Environment]::NewLine) -notmatch "65535") {
    throw "Controller did not reject an out-of-range port."
  }

  $broadRootStateDir = Join-Path $stateDir "broad-root-warning"
  $repoDriveRoot = [System.IO.Path]::GetPathRoot($repoRoot)
  $null = Invoke-ChildPowerShell @(
    "-File", $controller,
    "-Action", "Configure",
    "-ProjectRoot", $repoRoot,
    "-AllowedRoots", $repoDriveRoot,
    "-Tunnel", "none",
    "-StateDir", $broadRootStateDir,
    "-BridgeScript", $bridgeScript
  )
  $broadRootDoctor = Invoke-ChildPowerShell -Arguments @(
    "-File", $controller,
    "-Action", "Doctor",
    "-StateDir", $broadRootStateDir,
    "-BridgeScript", $bridgeScript
  ) -ExpectSuccess $false
  $broadRootDoctorJson = ($broadRootDoctor.Output -join [Environment]::NewLine) | ConvertFrom-Json
  if (@($broadRootDoctorJson.securityWarnings | Where-Object { $_ -like "allowed-root-is-drive-root:*" }).Count -ne 1) {
    throw "Doctor did not warn about a drive-root allowedRoots configuration."
  }

  $legacyStateDir = Join-Path $stateDir "legacy-plaintext"
  New-Item -ItemType Directory -Force -Path $legacyStateDir | Out-Null
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText(
    (Join-Path $legacyStateDir "cf-api.json"),
    (@{ accountId = ("a" * 32); apiToken = "test-only-placeholder"; kvNamespaceId = ("b" * 32) } | ConvertTo-Json),
    $utf8NoBom
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $legacyStateDir "worker-proxy.json"),
    (@{ workerBaseUrl = "https://bridge.example.workers.dev"; kvNamespaceId = ("b" * 32); kvKey = "current" } | ConvertTo-Json),
    $utf8NoBom
  )
  $null = Invoke-ChildPowerShell @(
    "-File", $controller,
    "-Action", "Configure",
    "-ProjectRoot", $repoRoot,
    "-Tunnel", "cloudflare-worker",
    "-PublicBaseUrl", "https://bridge.example.workers.dev",
    "-StateDir", $legacyStateDir,
    "-BridgeScript", $bridgeScript
  )
  $legacyOn = Invoke-ChildPowerShell -Arguments @(
    "-File", $controller,
    "-Action", "On",
    "-StateDir", $legacyStateDir,
    "-BridgeScript", $bridgeScript
  ) -ExpectSuccess $false
  $legacyResult = [System.IO.File]::ReadAllText((Join-Path $legacyStateDir "controller-result.json"), $utf8NoBom) | ConvertFrom-Json
  if ($legacyResult.message -notmatch "legacy plaintext") {
    throw "Controller did not reject a legacy plaintext Cloudflare credential.`n$($legacyOn.Output -join [Environment]::NewLine)"
  }

  $null = Invoke-ChildPowerShell @(
    "-File", $taskScript,
    "-Action", "Install",
    "-TaskName", $taskName,
    "-ControllerPath", $controller,
    "-WhatIf"
  )
  $taskStatus = Invoke-ChildPowerShell @(
    "-File", $taskScript,
    "-Action", "Status",
    "-TaskName", $taskName,
    "-ControllerPath", $controller
  )
  $taskStatusJson = ($taskStatus.Output -join [Environment]::NewLine) | ConvertFrom-Json
  if ($taskStatusJson.installed) { throw "Install -WhatIf unexpectedly registered a task." }

  $reboot = Invoke-ChildPowerShell -Arguments @(
    "-File", $controller,
    "-Action", "Reboot",
    "-StateDir", $stateDir,
    "-BridgeScript", $bridgeScript
  ) -ExpectSuccess $false
  $resultPath = Join-Path $stateDir "controller-result.json"
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $result = [System.IO.File]::ReadAllText($resultPath, $utf8NoBom) | ConvertFrom-Json
  if ($result.status -ne "failed" -or $result.message -notmatch "intentionally off") {
    $childText = $reboot.Output -join [Environment]::NewLine
    $resultText = $result | ConvertTo-Json -Depth 8
    throw "Reboot did not enforce the intentional-Off gate.`nChild output:`n$childText`nController result:`n$resultText"
  }

  [pscustomobject]@{
    ok = $true
    parsedScripts = $scripts.Count
    installerBackupVerified = $true
    configureStatus = $configureJson.status
    allowedRootsVerified = @($statusJson.profile.allowedRoots).Count
    dpapiRoundTripVerified = $dpapiMatches
    unrelatedPortOwnerPreserved = $true
    staleRecordedPidPreserved = $true
    legacyPlaintextRejected = $true
    unsafePublicUrlRejected = $true
    insecureExternalUrlRejected = $true
    invalidPortRejected = $true
    broadAllowedRootWarningVerified = $true
    cloudflaredPrechecksBypassed = $true
    quickTunnelBeforeKvVerified = $true
    initialDesiredState = $statusJson.desiredState.state
    credentialMode = $cfStatusJson.effectiveMode
    taskWhatIfInstalled = [bool]$taskStatusJson.installed
    rebootWhileOffExitCode = $reboot.ExitCode
    rebootWhileOffRejected = $true
  } | ConvertTo-Json -Depth 5
} finally {
  if ($listenerProcess -and -not $listenerProcess.HasExited) {
    Stop-Process -Id $listenerProcess.Id -Force -ErrorAction SilentlyContinue
  }
  if ($spoofedDevspaceProcess -and -not $spoofedDevspaceProcess.HasExited) {
    Stop-Process -Id $spoofedDevspaceProcess.Id -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $stateDir) {
    $resolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd("\") + "\"
    $resolvedState = [System.IO.Path]::GetFullPath($stateDir)
    if (-not $resolvedState.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedState) -notlike "codex-chatgpt-bridge-test-*") {
      throw "Refusing to clean unexpected test path: $resolvedState"
    }
    Remove-Item -LiteralPath $resolvedState -Recurse -Force
  }
}
