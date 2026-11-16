# Mulk Agent. A visible company program for one Windows computer.
# It shows the rules, sends an admin request, and applies the decision IT approved.
# It does not record keystrokes, screenshots, or file contents.
param(
  [switch]$Enforce
)

$ErrorActionPreference = 'Stop'
$Root = 'C:\ProgramData\MulkAgent'
$ConfigPath = Join-Path $Root 'device.json'
$LogPath = Join-Path $Root 'agent.log'
$MarkerPath = Join-Path $Root 'granted-admin.txt'
$StatusPath = Join-Path $Root 'status.txt'

function Write-AgentLog([string]$Message) {
  try {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Message
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
  } catch { }
}

function Get-AgentConfig {
  if (-not (Test-Path $ConfigPath)) { throw 'Mulk Agent is not installed on this computer.' }
  return Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Invoke-AgentRpc($Config, [string]$Name, $Body, [string]$RawJson) {
  $uri = ($Config.url.TrimEnd('/')) + '/rest/v1/rpc/' + $Name
  $headers = @{
    apikey = $Config.anon
    Authorization = 'Bearer ' + $Config.anon
    'Content-Type' = 'application/json'
  }
  if ($RawJson) { $json = $RawJson } else { $json = $Body | ConvertTo-Json -Compress }
  try {
    $res = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $json -UseBasicParsing
    if (-not $res.Content) { return $null }
    return $res.Content | ConvertFrom-Json
  } catch {
    $detail = $_.Exception.Message
    if ($_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
    throw $detail
  }
}

function ConvertTo-JsonArray($Items) {
  $parts = @()
  foreach ($item in @($Items)) {
    $parts += (ConvertTo-Json -InputObject $item -Compress -Depth 3)
  }
  if ($parts.Count -eq 0) { return '[]' }
  return '[' + ($parts -join ',') + ']'
}

function Get-InstalledPrograms {
  $paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($sid in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' })) {
    $paths += ('Registry::HKEY_USERS\' + $sid.PSChildName + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
  }
  $seen = @{}
  $list = @()
  foreach ($path in $paths) {
    foreach ($app in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
      $name = ([string]$app.DisplayName).Trim()
      if (-not $name) { continue }
      if ($app.SystemComponent -eq 1) { continue }
      if ($name -match '^(Update for |Security Update|Hotfix|KB[0-9])') { continue }
      $key = $name.ToLower()
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      $installed = $null
      $rawDate = [string]$app.InstallDate
      if ($rawDate -match '^\d{8}$') {
        $installed = $rawDate.Substring(0, 4) + '-' + $rawDate.Substring(4, 2) + '-' + $rawDate.Substring(6, 2)
      }
      $version = ([string]$app.DisplayVersion).Trim()
      $publisher = ([string]$app.Publisher).Trim()
      if ($name.Length -gt 160) { $name = $name.Substring(0, 160) }
      if ($version.Length -gt 80) { $version = $version.Substring(0, 80) }
      if ($publisher.Length -gt 120) { $publisher = $publisher.Substring(0, 120) }
      $list += @{ name = $name; version = $version; publisher = $publisher; installed_on = $installed }
      if ($list.Count -ge 500) { return $list }
    }
  }
  return $list
}

function Send-SoftwareInventory($Config) {
  $items = @(Get-InstalledPrograms)
  if ($items.Count -lt 1) {
    Write-AgentLog 'Software list was empty, so nothing was sent.'
    return
  }
  $tokenJson = ConvertTo-Json -InputObject ([string]$Config.token) -Compress
  $json = '{"p_token":' + $tokenJson + ',"p_items":' + (ConvertTo-JsonArray $items) + '}'
  $result = Invoke-AgentRpc $Config 'agent_sync_software' $null $json
  if ($result.baseline) {
    Write-AgentLog ("Software baseline saved. " + $result.kept + " programs.")
  } else {
    Write-AgentLog ("Software report: " + $result.added + " new, " + $result.removed + " removed, " + $result.kept + " unchanged.")
  }
}

function Send-UsbNotices($Config, $Policy) {
  $mode = [string]$Policy.usb
  if ($mode -ne 'block' -and $mode -ne 'read') { return }
  $statePath = Join-Path $Root 'usb-seen.txt'
  $seen = @{}
  if (Test-Path $statePath) {
    foreach ($line in @(Get-Content -Path $statePath -ErrorAction SilentlyContinue)) {
      if ($line) { $seen[$line] = $true }
    }
  }
  $now = @{}
  $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue)
  foreach ($drive in $drives) {
    $letter = [string]$drive.DeviceID
    $label = ([string]$drive.VolumeName).Trim()
    $key = $letter + '|' + $label
    $now[$key] = $true
    if ($seen.ContainsKey($key)) { continue }
    $file = if ($label) { "USB drive $letter $label" } else { "USB drive $letter" }
    if ($file.Length -gt 180) { $file = $file.Substring(0, 180) }
    $action = if ($mode -eq 'block') { 'blocked' } else { 'warned' }
    Invoke-AgentRpc $Config 'agent_report' @{
      p_token = $Config.token
      p_channel = 'usb'
      p_file_name = $file
      p_label = 'Removable storage'
      p_action = $action
    }
    Write-AgentLog "Reported $file as $action."
  }
  $keys = @($now.Keys)
  if ($keys.Count -eq 0) { Set-Content -Path $statePath -Value '' -Encoding UTF8 }
  else { Set-Content -Path $statePath -Value $keys -Encoding UTF8 }
}

function Get-Policy($Config) {
  return Invoke-AgentRpc $Config 'agent_policy' @{ p_token = $Config.token }
}

function Test-LocalAdmin([string]$Account) {
  $short = ($Account -split '\\')[-1]
  $lines = @(& net.exe localgroup Administrators 2>&1 | ForEach-Object { "$_".Trim() })
  return ($lines -contains $Account) -or ($lines -contains $short)
}

function Set-LocalAdmin([string]$Account, [bool]$Grant) {
  if ($Account -match '\\Administrator$' -or $Account -eq 'Administrator') {
    Write-AgentLog 'Left the built-in Administrator account unchanged.'
    return
  }
  $already = Test-LocalAdmin $Account
  if ($Grant -and -not $already) {
    & net.exe localgroup Administrators $Account /add | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Windows refused to grant admin rights to $Account." }
    Set-Content -Path $MarkerPath -Value $Account -Encoding UTF8
    Write-AgentLog "Granted temporary admin rights to $Account."
  } elseif (-not $Grant -and (Test-Path $MarkerPath)) {
    $marked = (Get-Content -Path $MarkerPath -Raw -Encoding UTF8).Trim()
    if ($marked -eq $Account -and $already) {
      & net.exe localgroup Administrators $Account /delete | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "Windows refused to remove admin rights from $Account." }
      Write-AgentLog "Removed admin rights from $Account because the approved window ended."
    }
    Remove-Item -Path $MarkerPath -Force -ErrorAction SilentlyContinue
  } elseif (-not $Grant -and $already) {
    Write-AgentLog "$Account is still a local administrator. Mulk Agent will not remove an admin it did not grant."
  }
}

function Set-UsbPolicy([string]$Mode) {
  $paths = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}'
  )
  foreach ($path in $paths) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Remove-ItemProperty -Path $path -Name Deny_All -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $path -Name Deny_Write -ErrorAction SilentlyContinue
    if ($Mode -eq 'block') {
      New-ItemProperty -Path $path -Name Deny_All -Value 1 -PropertyType DWord -Force | Out-Null
    } elseif ($Mode -eq 'read') {
      New-ItemProperty -Path $path -Name Deny_Write -Value 1 -PropertyType DWord -Force | Out-Null
    }
  }
  $label = switch ($Mode) { 'block' { 'blocked' } 'read' { 'read only' } default { 'allowed' } }
  Write-AgentLog "USB storage set to $label. New USB connections pick this up."
}

function Invoke-Enforce {
  $config = Get-AgentConfig
  $policy = Get-Policy $config
  $user = [string]$policy.windows_user
  if (-not $user) { $user = [string]$config.windows_user }
  $grant = ($policy.admin -eq 'elevated' -or $policy.admin -eq 'standing') -and -not [bool]$policy.hold
  Set-LocalAdmin $user $grant
  $usb = [string]$policy.usb
  if ([bool]$policy.hold) { $usb = 'block' }
  if ($usb -notin @('block', 'read', 'allow')) { $usb = 'block' }
  Set-UsbPolicy $usb
  try { Send-SoftwareInventory $config } catch { Write-AgentLog ("Software report failed: " + $_.Exception.Message) }
  try { Send-UsbNotices $config $policy } catch { Write-AgentLog ("USB report failed: " + $_.Exception.Message) }
  $summary = if ([bool]$policy.hold) {
    'On hold. Admin rights are off and USB storage is blocked.'
  } elseif ($policy.admin -eq 'standing') {
    'Standing admin is on.'
  } elseif ($policy.admin -eq 'elevated') {
    'Temporary admin is on until ' + [string]$policy.elevation_ends_at
  } else {
    'Standard user.'
  }
  Set-Content -Path $StatusPath -Value $summary -Encoding UTF8
  Write-AgentLog $summary
}

if ($Enforce) {
  try { Invoke-Enforce } catch {
    Write-AgentLog ("Enforcement failed: " + $_.Exception.Message)
    exit 1
  }
  exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = New-Object System.Threading.Mutex($false, 'Local\MulkAgentWindow')
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Mulk Agent'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(520, 680)
$form.MinimumSize = New-Object System.Drawing.Size(480, 600)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.BackColor = [System.Drawing.Color]::FromArgb(244, 245, 247)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Mulk Agent'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 16)
$form.Controls.Add($title)

$intro = New-Object System.Windows.Forms.Label
$intro.Text = 'This window is the company agent for this computer. It shows the rules IT set, reports installed programs, and reports a removable drive. It does not read documents, keystrokes, or screenshots.'
$intro.Size = New-Object System.Drawing.Size(460, 64)
$intro.Location = New-Object System.Drawing.Point(20, 52)
$form.Controls.Add($intro)

$status = New-Object System.Windows.Forms.Label
$status.Size = New-Object System.Drawing.Size(460, 72)
$status.Location = New-Object System.Drawing.Point(20, 124)
$form.Controls.Add($status)

$rules = New-Object System.Windows.Forms.ListBox
$rules.Size = New-Object System.Drawing.Size(460, 130)
$rules.Location = New-Object System.Drawing.Point(20, 204)
$form.Controls.Add($rules)

$nameLabel = New-Object System.Windows.Forms.Label
$nameLabel.Text = 'Your name'
$nameLabel.Location = New-Object System.Drawing.Point(20, 346)
$nameLabel.AutoSize = $true
$form.Controls.Add($nameLabel)

$nameBox = New-Object System.Windows.Forms.TextBox
$nameBox.Location = New-Object System.Drawing.Point(20, 368)
$nameBox.Size = New-Object System.Drawing.Size(460, 28)
$form.Controls.Add($nameBox)

$reasonLabel = New-Object System.Windows.Forms.Label
$reasonLabel.Text = 'Why you need admin rights'
$reasonLabel.Location = New-Object System.Drawing.Point(20, 404)
$reasonLabel.AutoSize = $true
$form.Controls.Add($reasonLabel)

$reasonBox = New-Object System.Windows.Forms.TextBox
$reasonBox.Location = New-Object System.Drawing.Point(20, 426)
$reasonBox.Size = New-Object System.Drawing.Size(460, 28)
$form.Controls.Add($reasonBox)

$ask = New-Object System.Windows.Forms.Button
$ask.Text = 'Request admin rights'
$ask.Location = New-Object System.Drawing.Point(20, 466)
$ask.Size = New-Object System.Drawing.Size(180, 34)
$form.Controls.Add($ask)

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = 'Refresh'
$refresh.Location = New-Object System.Drawing.Point(210, 466)
$refresh.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($refresh)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(20, 514)
$logBox.Size = New-Object System.Drawing.Size(460, 80)
$form.Controls.Add($logBox)

function Update-LogView {
  if (Test-Path $LogPath) {
    $lines = Get-Content -Path $LogPath -Tail 8 -ErrorAction SilentlyContinue
    $logBox.Text = ($lines -join [Environment]::NewLine)
  }
}

function Update-Window {
  try {
    $config = Get-AgentConfig
    $policy = Get-Policy $config
    if (-not $nameBox.Text -and $policy.assigned_to) { $nameBox.Text = [string]$policy.assigned_to }
    $adminText = switch ([string]$policy.admin) {
      'standing' { 'Standing admin' }
      'elevated' { 'Temporary admin until ' + [string]$policy.elevation_ends_at }
      default { 'Standard user' }
    }
    $holdText = if ([bool]$policy.hold) { 'On hold. ' + [string]$policy.hold_reason } else { 'Not on hold' }
    $status.Text = @(
      ([string]$policy.tag + '  ' + [string]$policy.description),
      $adminText,
      $holdText
    ) -join [Environment]::NewLine
    $rules.Items.Clear()
    foreach ($rule in @($policy.rules)) { [void]$rules.Items.Add([string]$rule) }
    Update-LogView
  } catch {
    $status.Text = 'Could not reach Control. ' + $_.Exception.Message
  }
}

$ask.Add_Click({
  try {
    $who = $nameBox.Text.Trim()
    $why = $reasonBox.Text.Trim()
    if ($who.Length -lt 2) { throw 'Enter your name.' }
    if ($why.Length -lt 8) { throw 'Write a short reason, at least a few words.' }
    $config = Get-AgentConfig
    Invoke-AgentRpc $config 'agent_request' @{ p_token = $config.token; p_requested_by = $who; p_reason = $why }
    $reasonBox.Text = ''
    Write-AgentLog "Admin request sent for $who."
    [System.Windows.Forms.MessageBox]::Show('Request sent. IT will see it in Control. You stay a standard user until someone approves a short window.', 'Mulk Agent')
    Update-LogView
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Mulk Agent')
  }
})

$refresh.Add_Click({ Update-Window })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-Window })
$timer.Start()
$form.Add_Shown({ Update-Window })
[void]$form.ShowDialog()
$timer.Stop()
$mutex.ReleaseMutex() | Out-Null
