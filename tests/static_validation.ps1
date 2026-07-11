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

  $configure = Invoke-ChildPowerShell @(
    "-File", $controller,
    "-Action", "Configure",
    "-ProjectRoot", $repoRoot,
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
  if ($statusJson.desiredState.state -ne "stopped") { throw "Configure must default to intentionally stopped." }

  $cfStatus = Invoke-ChildPowerShell @(
    "-File", $cfConfigScript,
    "-Action", "Status",
    "-StateDir", $stateDir
  )
  $cfStatusJson = ($cfStatus.Output -join [Environment]::NewLine) | ConvertFrom-Json
  if ($cfStatusJson.effectiveMode -ne "missing") { throw "Fresh test state unexpectedly contains a Cloudflare credential." }

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
    initialDesiredState = $statusJson.desiredState.state
    credentialMode = $cfStatusJson.effectiveMode
    taskWhatIfInstalled = [bool]$taskStatusJson.installed
    rebootWhileOffExitCode = $reboot.ExitCode
    rebootWhileOffRejected = $true
  } | ConvertTo-Json -Depth 5
} finally {
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
