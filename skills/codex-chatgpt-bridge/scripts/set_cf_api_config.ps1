[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateSet("Set", "Status", "Clear")]
  [string]$Action = "Status",

  [ValidatePattern('^[A-Fa-f0-9]{32}$')]
  [string]$AccountId,

  [ValidatePattern('^[A-Fa-f0-9]{32}$')]
  [string]$KvNamespaceId,

  [string]$WorkerBaseUrl,

  [ValidateNotNullOrEmpty()]
  [string]$KvKey = "current",

  [string]$StateDir = (Join-Path $env:LOCALAPPDATA "devspace-bridge")
)

$ErrorActionPreference = "Stop"
$ConfigPath = Join-Path $StateDir "cf-api.protected.json"
$LegacyConfigPath = Join-Path $StateDir "cf-api.json"
$ProfilePath = Join-Path $StateDir "controller-profile.json"
$WorkerProxyConfigPath = Join-Path $StateDir "worker-proxy.json"

function Write-Json($obj) {
  [Console]::Out.WriteLine(($obj | ConvertTo-Json -Depth 6))
}

function Write-JsonFileAtomic($obj, [string]$path) {
  $json = $obj | ConvertTo-Json -Depth 6
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

function Ensure-DpapiType {
  if (-not ("System.Security.Cryptography.ProtectedData" -as [type])) {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
  }
  if (-not ("System.Security.Cryptography.ProtectedData" -as [type])) {
    throw "Windows DPAPI support could not be loaded in this PowerShell runtime."
  }
}

function Get-JsonFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json
}

switch ($Action) {
  "Status" {
    $configured = Test-Path -LiteralPath $ConfigPath
    $legacyPresent = Test-Path -LiteralPath $LegacyConfigPath
    $metadata = $null
    if ($configured) {
      $utf8 = New-Object System.Text.UTF8Encoding $false
      $saved = [System.IO.File]::ReadAllText($ConfigPath, $utf8) | ConvertFrom-Json
      $metadata = [ordered]@{
        accountIdPresent = [bool]$saved.accountId
        kvNamespaceIdPresent = [bool]$saved.kvNamespaceId
        protectedTokenPresent = [bool]$saved.apiTokenProtected
        protection = [string]$saved.protection
      }
    }
    $workerProxy = Get-JsonFile $WorkerProxyConfigPath
    Write-Json ([ordered]@{
      action = "Status"
      configured = ($configured -or $legacyPresent)
      effectiveMode = if ($configured -and $legacyPresent) { "dpapi-with-plaintext-legacy" } elseif ($configured) { "dpapi" } elseif ($legacyPresent) { "plaintext-legacy" } else { "missing" }
      path = $ConfigPath
      legacyPath = $LegacyConfigPath
      legacyPresent = $legacyPresent
      metadata = $metadata
      workerProxyPath = $WorkerProxyConfigPath
      workerProxyConfigured = [bool]$workerProxy
      workerProxyMetadata = if ($workerProxy) {
        [ordered]@{
          workerBaseUrlPresent = [bool]$workerProxy.workerBaseUrl
          kvNamespaceIdPresent = [bool]$workerProxy.kvNamespaceId
          kvKeyPresent = [bool]$workerProxy.kvKey
        }
      } else { $null }
    })
    break
  }

  "Clear" {
    if ((Test-Path -LiteralPath $ConfigPath) -and $PSCmdlet.ShouldProcess($ConfigPath, "Delete protected Cloudflare API configuration")) {
      Remove-Item -LiteralPath $ConfigPath -Force
    }
    if ((Test-Path -LiteralPath $LegacyConfigPath) -and $PSCmdlet.ShouldProcess($LegacyConfigPath, "Delete legacy plaintext Cloudflare API configuration")) {
      Remove-Item -LiteralPath $LegacyConfigPath -Force
    }
    Write-Json ([ordered]@{
      action = "Clear"
      configured = ((Test-Path -LiteralPath $ConfigPath) -or (Test-Path -LiteralPath $LegacyConfigPath))
      path = $ConfigPath
      legacyPath = $LegacyConfigPath
    })
    break
  }

  "Set" {
    if (-not $AccountId) { throw "-AccountId is required for Action Set." }
    if (-not $KvNamespaceId) { throw "-KvNamespaceId is required for Action Set." }

    $profile = Get-JsonFile $ProfilePath
    $existingProxy = Get-JsonFile $WorkerProxyConfigPath
    $effectiveWorkerBaseUrl = if ($WorkerBaseUrl) {
      $WorkerBaseUrl.TrimEnd("/")
    } elseif ($profile -and $profile.tunnel -eq "cloudflare-worker" -and $profile.publicBaseUrl) {
      ([string]$profile.publicBaseUrl).TrimEnd("/")
    } elseif ($existingProxy -and $existingProxy.workerBaseUrl) {
      ([string]$existingProxy.workerBaseUrl).TrimEnd("/")
    } else {
      $null
    }
    if ($profile -and $profile.tunnel -eq "cloudflare-worker" -and -not $effectiveWorkerBaseUrl) {
      throw "The cloudflare-worker controller profile is missing publicBaseUrl. Run controller Configure first."
    }
    if ($profile -and $profile.tunnel -eq "cloudflare-worker" -and $WorkerBaseUrl -and
        -not $effectiveWorkerBaseUrl.Equals(([string]$profile.publicBaseUrl).TrimEnd("/"), [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "WorkerBaseUrl does not match the saved cloudflare-worker profile. Run controller Configure first to change the stable URL."
    }
    if ($effectiveWorkerBaseUrl) {
      $parsedWorkerUri = $null
      if (-not [Uri]::TryCreate($effectiveWorkerBaseUrl, [UriKind]::Absolute, [ref]$parsedWorkerUri) -or
          $parsedWorkerUri.Scheme -ne "https" -or
          [string]::IsNullOrWhiteSpace($parsedWorkerUri.Host) -or
          -not [string]::IsNullOrWhiteSpace($parsedWorkerUri.UserInfo) -or
          -not [string]::IsNullOrWhiteSpace($parsedWorkerUri.Query) -or
          -not [string]::IsNullOrWhiteSpace($parsedWorkerUri.Fragment)) {
        throw "WorkerBaseUrl must be an absolute HTTPS URL without credentials, query, or fragment."
      }
    }
    $workerProxyRecord = if ($effectiveWorkerBaseUrl) {
      [ordered]@{
        workerBaseUrl = $effectiveWorkerBaseUrl
        kvNamespaceId = $KvNamespaceId
        kvKey = if ($KvKey) { $KvKey } else { "current" }
        updatedAt = (Get-Date).ToString("o")
      }
    } else { $null }

    $secureToken = Read-Host "Cloudflare API token (Workers KV Storage: Edit only)" -AsSecureString
    $bstr = [IntPtr]::Zero
    $plainBytes = $null
    $roundTripBytes = $null
    try {
      $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
      $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
      if ([string]::IsNullOrWhiteSpace($plainToken)) {
        throw "The API token cannot be empty."
      }
      $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plainToken)
      Ensure-DpapiType
      $cipherBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
      )
      $roundTripBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $cipherBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
      )
      $roundTripMatches = ($plainBytes.Length -eq $roundTripBytes.Length)
      if ($roundTripMatches) {
        for ($index = 0; $index -lt $plainBytes.Length; $index++) {
          if ($plainBytes[$index] -ne $roundTripBytes[$index]) {
            $roundTripMatches = $false
            break
          }
        }
      }
      if (-not $roundTripMatches) {
        throw "DPAPI round-trip verification failed; credential was not written."
      }
      $record = [ordered]@{
        accountId = $AccountId
        kvNamespaceId = $KvNamespaceId
        apiTokenProtected = [Convert]::ToBase64String($cipherBytes)
        protection = "Windows-DPAPI-CurrentUser"
        updatedAt = (Get-Date).ToString("o")
      }
      $targetDescription = if ($workerProxyRecord) {
        "Write DPAPI-protected Cloudflare API configuration and local-only Worker proxy metadata"
      } else {
        "Write DPAPI-protected Cloudflare API configuration"
      }
      if ($PSCmdlet.ShouldProcess($ConfigPath, $targetDescription)) {
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        Write-JsonFileAtomic $record $ConfigPath
        if ($workerProxyRecord) {
          Write-JsonFileAtomic $workerProxyRecord $WorkerProxyConfigPath
        }
        if (Test-Path -LiteralPath $LegacyConfigPath) {
          Remove-Item -LiteralPath $LegacyConfigPath -Force
        }
      }
    } finally {
      if ($roundTripBytes) { [Array]::Clear($roundTripBytes, 0, $roundTripBytes.Length) }
      if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
      if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
      $plainToken = $null
      $cipherBytes = $null
    }

    Write-Json ([ordered]@{
      action = "Set"
      configured = (Test-Path -LiteralPath $ConfigPath)
      path = $ConfigPath
      protection = "Windows-DPAPI-CurrentUser"
      workerProxyPath = $WorkerProxyConfigPath
      workerProxyConfigured = (Test-Path -LiteralPath $WorkerProxyConfigPath)
      legacyPlaintextPresent = (Test-Path -LiteralPath $LegacyConfigPath)
      note = "The token is encrypted for the current Windows user and is never printed. When a Worker URL is available, local-only worker-proxy.json metadata is synchronized too; keep it out of git. A legacy plaintext cf-api.json is removed after the DPAPI write and round-trip verification succeed."
    })
    break
  }
}
