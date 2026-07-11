param(
  [string]$CodexHome = "$env:USERPROFILE\.codex",
  [switch]$BackupExisting,
  [switch]$ForceOverwrite,
  [switch]$RegisterRestartTask
)

$ErrorActionPreference = "Stop"

if ($BackupExisting -and $ForceOverwrite) {
  throw "-BackupExisting and -ForceOverwrite are mutually exclusive. Backup is already the default."
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $repoRoot "skills\codex-chatgpt-bridge"
$targetRoot = Join-Path $CodexHome "skills"
$target = Join-Path $targetRoot "codex-chatgpt-bridge"

if (-not (Test-Path -LiteralPath $source)) {
  throw "Skill source not found: $source"
}

New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

if (Test-Path -LiteralPath $target) {
  if (-not $ForceOverwrite) {
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    $backup = "$target.backup-$stamp"
    Move-Item -LiteralPath $target -Destination $backup
    Write-Host "Backed up existing skill to $backup"
  } else {
    Remove-Item -LiteralPath $target -Recurse -Force
  }
}

Copy-Item -LiteralPath $source -Destination $target -Recurse

Write-Host "Installed codex-chatgpt-bridge skill to $target"
if ($RegisterRestartTask) {
  $taskScript = Join-Path $target "scripts\restart_task.ps1"
  & $taskScript -Action Install
}
Write-Host "Restart Codex or reload skills to use it."


