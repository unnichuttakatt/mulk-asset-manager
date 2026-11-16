# Mulk Agent. A visible company program for one Windows computer.
# It shows the rules, sends an admin request, and applies the decision IT approved.
# It reports installed programs, USB devices, the public IP city/country,
# web searches, active time, and which app is in front.
# It does not record keystrokes, screenshots, documents, page contents, or GPS.
# Sign-in lock is no longer used. If an older copy blocked sign-in, this copy removes that block.
# IT can ask to open Windows Quick Assist. The person must choose Allow first.
# A computer still running after 6:00 PM reminds the person, the next time they
# use it, to shut down when leaving. Office hours are 8:00 AM to 6:00 PM.
# The screen is not saved, and the keyboard is not recorded.
param(
  [switch]$Enforce,
  [switch]$Sample,
  [switch]$Watch
)

$ErrorActionPreference = 'Stop'
$Root = 'C:\ProgramData\MulkAgent'
$AgentFile = Join-Path $Root 'MulkAgent.ps1'
$ConfigPath = Join-Path $Root 'device.json'
$LogPath = Join-Path $Root 'agent.log'
$MarkerPath = Join-Path $Root 'granted-admin.txt'
$StatusPath = Join-Path $Root 'status.txt'

function Write-AgentLog([string]$Message) {
  try {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Message
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    $item = Get-Item -Path $LogPath -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt 262144) {
      $tail = @(Get-Content -Path $LogPath -Tail 80 -ErrorAction SilentlyContinue)
      Set-Content -Path $LogPath -Value $tail -Encoding UTF8
    }
  } catch { }
}

function Test-Due([string]$Name, [int]$Minutes) {
  $path = Join-Path $Root ($Name + '.stamp')
  if (-not (Test-Path -Path $path)) { return $true }
  $age = (Get-Date) - (Get-Item -Path $path).LastWriteTime
  return ($age.TotalMinutes -ge $Minutes)
}

function Mark-Done([string]$Name) {
  Set-Content -Path (Join-Path $Root ($Name + '.stamp')) -Value (Get-Date -Format 'o') -Encoding ASCII
}

function Protect-AgentStore([string]$EnrolledUser) {
  if (-not (Test-Path -Path $Root)) { return }
  $system = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')).Translate([System.Security.Principal.NTAccount])
  $admins = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount])
  $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $none = [System.Security.AccessControl.PropagationFlags]::None
  $dir = Get-Acl -Path $Root
  $dir.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($dir.Access)) { [void]$dir.RemoveAccessRule($rule) }
  $dir.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, 'FullControl', $inherit, $none, 'Allow')))
  $dir.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', $inherit, $none, 'Allow')))
  $creator = (New-Object System.Security.Principal.SecurityIdentifier('S-1-3-0')).Translate([System.Security.Principal.NTAccount])
  $dir.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($creator, 'Modify', $inherit, 'InheritOnly', 'Allow')))
  $person = $null
  if ($EnrolledUser) {
    try { $person = New-Object System.Security.Principal.NTAccount($EnrolledUser) } catch { $person = $null }
  }
  if (-not $person) {
    $person = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([System.Security.Principal.NTAccount])
  }
  $dir.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($person, 'ReadAndExecute, CreateFiles, CreateDirectories, ReadAttributes, WriteAttributes, Synchronize', $inherit, $none, 'Allow')))
  Set-Acl -Path $Root -AclObject $dir
  foreach ($file in @($AgentFile, $ConfigPath)) {
    if (-not (Test-Path -Path $file)) { continue }
    $acl = Get-Acl -Path $file
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($person, 'ReadAndExecute', 'Allow')))
    Set-Acl -Path $file -AclObject $acl
  }
  if (Test-Path -Path $LogPath) {
    $acl = Get-Acl -Path $LogPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($person, 'ReadAndExecute, AppendData, WriteAttributes', 'Allow')))
    Set-Acl -Path $LogPath -AclObject $acl
  }
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

function Get-UsbDevices([string]$Mode) {
  $items = @()
  $seen = @{}
  $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
    $_.PNPDeviceID -like 'USB\*' -and $_.Name -and $_.Name -notmatch 'Root Hub|Host Controller|USB Hub'
  })
  foreach ($device in $devices) {
    $name = ([string]$device.Name).Trim()
    $id = ([string]$device.PNPDeviceID).Trim().ToLower()
    if (-not $name -or -not $id -or $seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    if ($name.Length -gt 160) { $name = $name.Substring(0, 160) }
    $items += @{ key = 'pnp|' + $id; name = $name; label = 'USB device'; action = 'plugged' }
  }
  $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue)
  foreach ($drive in $drives) {
    $letter = [string]$drive.DeviceID
    $label = ([string]$drive.VolumeName).Trim()
    $key = 'vol|' + $letter.ToLower() + '|' + $label.ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $file = if ($label) { "USB drive $letter $label" } else { "USB drive $letter" }
    if ($file.Length -gt 160) { $file = $file.Substring(0, 160) }
    $action = switch ($Mode) { 'block' { 'blocked' } 'read' { 'warned' } default { 'plugged' } }
    $items += @{ key = $key; name = $file; label = 'Removable storage'; action = $action }
  }
  return $items
}

function Send-UsbNotices($Config, $Policy) {
  $mode = [string]$Policy.usb
  $statePath = Join-Path $Root 'usb-seen.txt'
  $baselinePath = Join-Path $Root 'usb-baseline.txt'
  $items = @(Get-UsbDevices $mode)
  $seen = @{}
  if (Test-Path $statePath) {
    foreach ($line in @(Get-Content -Path $statePath -ErrorAction SilentlyContinue)) {
      if ($line) { $seen[$line] = $true }
    }
  }
  $baseline = Test-Path $baselinePath
  $now = @()
  $reported = 0
  foreach ($item in $items) {
    $now += [string]$item.key
    if (-not $baseline) { continue }
    if ($seen.ContainsKey([string]$item.key)) { continue }
    Invoke-AgentRpc $Config 'agent_report' @{
      p_token = $Config.token
      p_channel = 'usb'
      p_file_name = [string]$item.name
      p_label = [string]$item.label
      p_action = [string]$item.action
    }
    $reported += 1
    Write-AgentLog ("USB " + $item.action + ": " + $item.name)
  }
  if ($now.Count -eq 0) { Set-Content -Path $statePath -Value '' -Encoding UTF8 }
  else { Set-Content -Path $statePath -Value $now -Encoding UTF8 }
  if (-not $baseline) {
    Set-Content -Path $baselinePath -Value '1' -Encoding UTF8
    Write-AgentLog ("USB baseline saved. " + $items.Count + " devices already connected. A device plugged in after this is reported.")
  } elseif ($reported -eq 0) {
    Write-AgentLog 'No new USB devices.'
  }
}

function Get-LocalIp {
  $configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue)
  foreach ($config in $configs) {
    foreach ($ip in @($config.IPAddress)) {
      $text = [string]$ip
      if ($text -match '^\d+\.\d+\.\d+\.\d+$' -and $text -notlike '127.*' -and $text -notlike '169.254.*') { return $text }
    }
  }
  return ''
}

function Get-PublicPresence {
  $cache = Join-Path $Root 'presence-cache.json'
  if (Test-Path $cache) {
    $age = (Get-Date) - (Get-Item $cache).LastWriteTime
    if ($age.TotalMinutes -lt 10) {
      try { return (Get-Content -Path $cache -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
  }
  foreach ($url in @('https://ipwho.is/', 'https://ipapi.co/json/')) {
    try {
      $remote = Invoke-RestMethod -Uri $url -TimeoutSec 12
      $ip = [string]$remote.ip
      if (-not $ip) { continue }
      $code = [string]$remote.country_code
      $country = [string]$remote.country
      if ($remote.country_name) { $country = [string]$remote.country_name }
      $obj = [pscustomobject]@{
        ip = $ip
        country_code = $code
        country = $country
        region = [string]$remote.region
        city = [string]$remote.city
      }
      $obj | ConvertTo-Json -Compress | Set-Content -Path $cache -Encoding UTF8
      return $obj
    } catch {
      Write-AgentLog ("Location lookup failed for ${url}: " + $_.Exception.Message)
    }
  }
  return $null
}

function Send-Presence($Config) {
  $local = Get-LocalIp
  $geo = Get-PublicPresence
  $result = Invoke-AgentRpc $Config 'agent_report_presence' @{
    p_token = $Config.token
    p_public_ip = $(if ($geo) { [string]$geo.ip } else { '' })
    p_local_ip = $local
    p_country_code = $(if ($geo) { [string]$geo.country_code } else { '' })
    p_country_name = $(if ($geo) { [string]$geo.country } else { '' })
    p_region_name = $(if ($geo) { [string]$geo.region } else { '' })
    p_city = $(if ($geo) { [string]$geo.city } else { '' })
  }
  $where = (([string]$result.city), ([string]$result.country_code)) -join ', '
  if ([bool]$result.alert) {
    Write-AgentLog ("Outside UAE: " + $where.Trim(', ') + " " + [string]$result.public_ip)
  } else {
    Write-AgentLog ("Location " + $where.Trim(', ') + " " + [string]$result.public_ip)
  }
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

function Initialize-MulkNative {
  if (-not ('MulkNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class MulkNative {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr OpenDesktop(string hDesktop, uint dwFlags, bool fInherit, uint dwDesiredAccess);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr hDesktop);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern int sqlite3_close(IntPtr db);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr tail);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern int sqlite3_step(IntPtr stmt);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern int sqlite3_finalize(IntPtr stmt);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern int sqlite3_bind_int64(IntPtr stmt, int index, long value);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern IntPtr sqlite3_column_text(IntPtr stmt, int iCol);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern int sqlite3_column_bytes(IntPtr stmt, int iCol);
  [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
  public static extern long sqlite3_column_int64(IntPtr stmt, int iCol);
  public static byte[] Utf8(string text) { return Encoding.UTF8.GetBytes(text + "\0"); }
  public static string ColumnText(IntPtr stmt, int iCol) {
    IntPtr p = sqlite3_column_text(stmt, iCol);
    if (p == IntPtr.Zero) return "";
    int n = sqlite3_column_bytes(stmt, iCol);
    if (n <= 0) return "";
    byte[] buf = new byte[n];
    Marshal.Copy(p, buf, 0, n);
    return Encoding.UTF8.GetString(buf);
  }
}
'@
  }
}

function Get-IdleSeconds {
  Initialize-MulkNative
  $info = New-Object MulkNative+LASTINPUTINFO
  $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
  [void][MulkNative]::GetLastInputInfo([ref]$info)
  $idle = [Environment]::TickCount - [int]$info.dwTime
  if ($idle -lt 0) { $idle = [int]([uint32]$idle) }
  return [int]($idle / 1000)
}

function Test-WorkstationLocked {
  try {
    Initialize-MulkNative
    $desk = [MulkNative]::OpenDesktop('Default', 0, $false, 0x100)
    if ($desk -eq [IntPtr]::Zero) { return $true }
    [void][MulkNative]::CloseDesktop($desk)
    return $false
  } catch {
    return $true
  }
}

function Read-UnattendedState {
  $path = Join-Path $Root 'unattended.json'
  $empty = @{ reported = $false; notice = $false; night = '' }
  if (-not (Test-Path $path)) { return $empty }
  try {
    $raw = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return @{ reported = [bool]$raw.reported; notice = [bool]$raw.notice; night = [string]$raw.night }
  } catch { return $empty }
}

function Save-UnattendedState($state) {
  $night = ([string]$state.night) -replace '[^0-9-]', ''
  $json = '{"reported":' + $(if ($state.reported) { 'true' } else { 'false' }) + ',"notice":' + $(if ($state.notice) { 'true' } else { 'false' }) + ',"night":"' + $night + '"}'
  Set-Content -Path (Join-Path $Root 'unattended.json') -Value $json -Encoding UTF8
}

function Get-OfficeCloseDate {
  $now = Get-Date
  $day = if ($now.Hour -lt 8) { $now.AddDays(-1) } else { $now }
  return $day.ToString('yyyy-MM-dd')
}

function Get-SecondsPastOfficeClose {
  $now = Get-Date
  $mins = $now.Hour * 60 + $now.Minute
  if ($mins -ge 480 -and $mins -lt 1200) { return 0 }
  $close = (Get-Date).Date.AddHours(18)
  if ($now.Hour -lt 8) { $close = $close.AddDays(-1) }
  try {
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
  } catch { return 0 }
  if (-not $boot -or $boot -ge $close) { return 0 }
  $past = [int]($now - $close).TotalSeconds
  if ($past -lt 7200) { return 0 }
  if ($past -gt 2592000) { return 2592000 }
  return $past
}

function Show-OfficeStandard {
  $mutex = New-Object System.Threading.Mutex($false, 'Local\MulkAgentUnattended')
  if (-not $mutex.WaitOne(0, $false)) { return $false }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.MessageBox]::Show(
      "This computer was still running after office hours.`r`n`r`nOffice hours are 8:00 AM to 6:00 PM. Shut the computer down when you leave the office. Leaving it on after 6:00 PM uses power and leaves it available overnight.`r`n`r`nIT has been told. This reminder does not include the screen or anything typed.",
      'Office standard'
    ) | Out-Null
    return $true
  } finally {
    $mutex.ReleaseMutex() | Out-Null
  }
}

function Publish-LeftOn($Config, [int]$Seconds, [string]$Night) {
  Invoke-AgentRpc $Config 'agent_report_unattended' @{
    p_token = [string]$Config.token
    p_idle_seconds = [int]$Seconds
    p_local_date = $Night
  }
}

function Update-Unattended {
  $state = Read-UnattendedState
  $night = Get-OfficeCloseDate
  $past = Get-SecondsPastOfficeClose
  $idle = 999999
  try { $idle = Get-IdleSeconds } catch { }
  if ($past -ge 7200 -and $idle -ge 180) {
    if (-not $state.reported -or $state.night -ne $night) {
      Publish-LeftOn (Get-AgentConfig) $past $night
      $state.reported = $true
      $state.notice = $true
      $state.night = $night
      Save-UnattendedState $state
      Write-AgentLog 'This computer was still on after 6:00 PM. Office hours are 8:00 AM to 6:00 PM. The person will be reminded to shut it down the next time they use it.'
    }
    return
  }
  if ($idle -lt 180 -and -not (Test-WorkstationLocked) -and $state.notice) {
    if (Show-OfficeStandard) {
      $state.notice = $false
      Save-UnattendedState $state
      Write-AgentLog 'Showed the office reminder to shut down when leaving. Office hours are 8:00 AM to 6:00 PM.'
    }
  }
}

function Test-SomeoneAtConsole {
  try {
    $out = & "$env:SystemRoot\System32\query.exe" user 2>$null
    foreach ($line in @($out)) {
      if ($line -match '\sActive\s') { return $true }
    }
  } catch { return $true }
  return $false
}

function Update-LeftOnSystem($Config) {
  if (Test-SomeoneAtConsole) { return }
  $past = Get-SecondsPastOfficeClose
  if ($past -lt 7200) { return }
  $night = Get-OfficeCloseDate
  $state = Read-UnattendedState
  if ($state.reported -and $state.night -eq $night) { return }
  Publish-LeftOn $Config $past $night
  $state.reported = $true
  $state.notice = $true
  $state.night = $night
  Save-UnattendedState $state
  Write-AgentLog 'This computer was still on after office hours with nobody signed in. Office hours are 8:00 AM to 6:00 PM.'
}

function Get-ForegroundApp {
  Initialize-MulkNative
  $hwnd = [MulkNative]::GetForegroundWindow()
  if ($hwnd -eq [IntPtr]::Zero) { return $null }
  $procId = [uint32]0
  [void][MulkNative]::GetWindowThreadProcessId($hwnd, [ref]$procId)
  $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $proc) { return $null }
  $key = $proc.ProcessName.ToLower()
  $names = @{
    chrome = 'Chrome'; msedge = 'Edge'; firefox = 'Firefox'; excel = 'Excel'; winword = 'Word'
    powerpnt = 'PowerPoint'; outlook = 'Outlook'; teams = 'Teams'; slack = 'Slack'; code = 'VS Code'
    explorer = 'File Explorer'; olk = 'Outlook'; winproj = 'Project'
  }
  if ($names.ContainsKey($key)) { return $names[$key] }
  if ($key -in @('lockapp', 'logonui', 'searchhost', 'shellexperiencehost')) { return $null }
  return $proc.ProcessName
}

function Read-ActivityQueue {
  $path = Join-Path $Root 'activity.json'
  $empty = @{ day = (Get-Date).ToString('yyyy-MM-dd'); activeSeconds = 0; apps = @(); lastTick = 0 }
  if (-not (Test-Path $path)) { return $empty }
  try {
    $raw = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $apps = @()
    foreach ($app in @($raw.apps)) {
      if ($app.name) { $apps += @{ name = [string]$app.name; seconds = [int]$app.seconds } }
    }
    return @{ day = [string]$raw.day; activeSeconds = [int]$raw.activeSeconds; apps = $apps; lastTick = [uint32]$raw.lastTick }
  } catch { return $empty }
}

function Save-ActivityQueue($queue) {
  $appsJson = ConvertTo-JsonArray @($queue.apps)
  $json = '{"day":' + (ConvertTo-Json ([string]$queue.day)) + ',"activeSeconds":' + [int]$queue.activeSeconds + ',"lastTick":' + [uint32]$queue.lastTick + ',"apps":' + $appsJson + '}'
  Set-Content -Path (Join-Path $Root 'activity.json') -Value $json -Encoding UTF8
}

function Add-ActivitySample {
  try { Update-Unattended } catch { Write-AgentLog ('Unattended check failed: ' + $_.Exception.Message) }
  $tick = [uint32][Environment]::TickCount
  $queue = Read-ActivityQueue
  $today = (Get-Date).ToString('yyyy-MM-dd')
  if ($queue.day -and $queue.day -ne $today -and ([int]$queue.activeSeconds -gt 0 -or @($queue.apps).Count -gt 0)) {
    $queue.lastTick = $tick
    Save-ActivityQueue $queue
    return
  }
  $elapsed = 60
  if ($queue.lastTick) {
    $elapsed = [int](([uint32]($tick - [uint32]$queue.lastTick)) / 1000)
    if ($elapsed -lt 15) { return }
    if ($elapsed -gt 180) { $elapsed = 60 }
  }
  $queue.day = $today
  $queue.lastTick = $tick
  $idle = Get-IdleSeconds
  $app = Get-ForegroundApp
  if ($idle -lt 180 -and $app) {
    $queue.activeSeconds = [int]$queue.activeSeconds + $elapsed
    $apps = @($queue.apps)
    $found = $false
    foreach ($row in $apps) {
      if ($row.name -eq $app) { $row.seconds = [int]$row.seconds + $elapsed; $found = $true }
    }
    if (-not $found) { $apps += @{ name = $app; seconds = $elapsed } }
    $queue.apps = $apps
  }
  Save-ActivityQueue $queue
}

function Get-EnrolledProfile {
  try { $account = [string](Get-AgentConfig).windows_user } catch { return $null }
  $short = ($account -split '\\')[-1]
  if (-not $short) { return $null }
  foreach ($key in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
    $path = [string](Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
    if ($path -and $path.TrimEnd('\') -like "*\$short") { return $path }
  }
  return $null
}

function Get-QueryValue([string]$Url, [string]$Name) {
  try { $query = ([uri]$Url).Query.TrimStart('?') } catch { return $null }
  foreach ($part in $query.Split('&')) {
    $pair = $part.Split('=', 2)
    if ($pair.Length -eq 2 -and $pair[0] -eq $Name) {
      return [uri]::UnescapeDataString($pair[1].Replace('+', ' ')).Trim()
    }
  }
  return $null
}

function Get-SearchFromUrl([string]$Url) {
  try { $uri = [uri]$Url } catch { return $null }
  $hostName = $uri.Host.ToLower()
  $path = $uri.AbsolutePath.ToLower()
  $engine = $null
  $query = $null
  if ($hostName -match '(^|\.)google\.' -and $path -eq '/search') { $engine = 'Google'; $query = Get-QueryValue $Url 'q' }
  elseif ($hostName -eq 'www.bing.com' -and $path -eq '/search') { $engine = 'Bing'; $query = Get-QueryValue $Url 'q' }
  elseif ($hostName -match 'duckduckgo\.com') { $engine = 'DuckDuckGo'; $query = Get-QueryValue $Url 'q' }
  elseif ($hostName -match 'search\.yahoo\.') { $engine = 'Yahoo'; $query = Get-QueryValue $Url 'p' }
  elseif ($hostName -match 'youtube\.com' -and $path -eq '/results') { $engine = 'YouTube'; $query = Get-QueryValue $Url 'search_query' }
  if (-not $engine -or -not $query) { return $null }
  if ($query.Length -lt 1 -or $query.Length -gt 300) { return $null }
  return @{ engine = $engine; query = $query }
}

function Invoke-HistoryQuery($DbPath, $Sql, $Since) {
  Initialize-MulkNative
  $uri = 'file:' + ($DbPath -replace '\\', '/') + '?mode=ro&immutable=1'
  $db = [IntPtr]::Zero
  $stmt = [IntPtr]::Zero
  $rows = @()
  $opened = [MulkNative]::sqlite3_open_v2([MulkNative]::Utf8($uri), [ref]$db, 1, [IntPtr]::Zero)
  if ($opened -ne 0) { throw "Could not open browser history ($opened)." }
  try {
    $prepared = [MulkNative]::sqlite3_prepare_v2($db, [MulkNative]::Utf8($Sql), -1, [ref]$stmt, [IntPtr]::Zero)
    if ($prepared -ne 0) { throw "Could not read browser history ($prepared)." }
    if ($Sql.Contains('?')) { [void][MulkNative]::sqlite3_bind_int64($stmt, 1, [int64]$Since) }
    while ([MulkNative]::sqlite3_step($stmt) -eq 100) {
      $rows += @{
        url = [MulkNative]::ColumnText($stmt, 0)
        visited = [int64][MulkNative]::sqlite3_column_int64($stmt, 1)
      }
      if ($rows.Count -ge 80) { break }
    }
  } finally {
    if ($stmt -ne [IntPtr]::Zero) { [void][MulkNative]::sqlite3_finalize($stmt) }
    if ($db -ne [IntPtr]::Zero) { [void][MulkNative]::sqlite3_close($db) }
  }
  return $rows
}

function Copy-BrowserDb($Source, $DestDir, $Leaf) {
  New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
  foreach ($suffix in @('', '-wal', '-shm')) {
    $from = $Source + $suffix
    if (Test-Path $from) { Copy-Item -Path $from -Destination (Join-Path $DestDir ($Leaf + $suffix)) -Force }
  }
}

function Read-NewSearches {
  $cursorPath = Join-Path $Root 'search-cursors.json'
  $cursors = @{}
  $haveCursor = Test-Path $cursorPath
  if ($haveCursor) {
    try {
      $saved = Get-Content -Path $cursorPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($prop in $saved.PSObject.Properties) { $cursors[$prop.Name] = [int64]$prop.Value }
    } catch { $haveCursor = $false }
  }
  $profile = Get-EnrolledProfile
  if (-not $profile) { return @{ searches = @(); cursors = $cursors; baseline = -not $haveCursor } }
  $sources = @()
  $chromeRoot = Join-Path $profile 'AppData\Local\Google\Chrome\User Data'
  $edgeRoot = Join-Path $profile 'AppData\Local\Microsoft\Edge\User Data'
  foreach ($root in @($chromeRoot, $edgeRoot)) {
    if (-not (Test-Path $root)) { continue }
    foreach ($dir in @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
      $history = Join-Path $dir.FullName 'History'
      if (Test-Path $history) { $sources += @{ path = $history; kind = 'chromium'; leaf = 'History' } }
    }
  }
  $firefox = Join-Path $profile 'AppData\Roaming\Mozilla\Firefox\Profiles'
  if (Test-Path $firefox) {
    foreach ($dir in @(Get-ChildItem $firefox -Directory -ErrorAction SilentlyContinue)) {
      $places = Join-Path $dir.FullName 'places.sqlite'
      if (Test-Path $places) { $sources += @{ path = $places; kind = 'firefox'; leaf = 'places.sqlite' } }
    }
  }
  $found = @()
  $next = @{}
  foreach ($source in $sources) {
    $key = $source.path.ToLower()
    $since = 0
    $known = $cursors.ContainsKey($key)
    if ($known) { $since = [int64]$cursors[$key] }
    $copyDir = Join-Path $env:TEMP ('MulkHist-' + [guid]::NewGuid().ToString('N'))
    try {
      Copy-BrowserDb $source.path $copyDir $source.leaf
      $copy = Join-Path $copyDir $source.leaf
      if (-not $known) {
        if ($source.kind -eq 'firefox') { $sql = "select '', coalesce(max(last_visit_date), 0) from moz_places" }
        else { $sql = "select '', coalesce(max(last_visit_time), 0) from urls" }
        $maxRows = @(Invoke-HistoryQuery $copy $sql 0)
        $next[$key] = $(if ($maxRows.Count) { [int64]$maxRows[0].visited } else { 0 })
        continue
      }
      if ($source.kind -eq 'firefox') {
        $sql = "select url, last_visit_date from moz_places where last_visit_date > ? and url is not null order by last_visit_date asc limit 80"
      } else {
        $sql = "select url, last_visit_time from urls where last_visit_time > ? and url is not null order by last_visit_time asc limit 80"
      }
      $rows = @(Invoke-HistoryQuery $copy $sql $since)
      $max = $since
      foreach ($row in $rows) {
        if ([int64]$row.visited -gt $max) { $max = [int64]$row.visited }
        $parsed = Get-SearchFromUrl ([string]$row.url)
        if (-not $parsed) { continue }
        if ($source.kind -eq 'firefox') {
          $when = ([datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc')).AddTicks([int64]$row.visited * 10)
        } else {
          $when = ([datetime]::SpecifyKind([datetime]'1601-01-01', 'Utc')).AddTicks([int64]$row.visited * 10)
        }
        $found += @{ query = $parsed.query; engine = $parsed.engine; at = $when.ToString('o') }
      }
      $next[$key] = $max
    } catch {
      Write-AgentLog ("Search read failed for " + $source.path + ": " + $_.Exception.Message)
      if ($cursors.ContainsKey($key)) { $next[$key] = $cursors[$key] }
    } finally {
      Remove-Item -Path $copyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  return @{ searches = @($found | Select-Object -First 80); cursors = $next; baseline = -not $haveCursor }
}

function Save-SearchCursors($cursors) {
  $obj = @{}
  foreach ($key in $cursors.Keys) { $obj[$key] = [string]$cursors[$key] }
  $obj | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $Root 'search-cursors.json') -Encoding UTF8
}

function Send-Usage($Config) {
  $batch = Read-NewSearches
  $queue = Read-ActivityQueue
  $searches = @()
  if (-not $batch.baseline) { $searches = @($batch.searches) }
  $active = [int]$queue.activeSeconds
  $apps = @($queue.apps)
  if ($batch.baseline) {
    Save-SearchCursors $batch.cursors
    Write-AgentLog 'Search baseline saved. Earlier browser searches are not imported.'
  }
  if ($active -le 0 -and $apps.Count -eq 0 -and $searches.Count -eq 0) {
    if (-not $batch.baseline) { Save-SearchCursors $batch.cursors }
    return
  }
  $tokenJson = ConvertTo-Json -InputObject ([string]$Config.token) -Compress
  $json = '{"p_token":' + $tokenJson + ',"p_date":' + (ConvertTo-Json ([string]$queue.day)) + ',"p_active_seconds":' + $active + ',"p_apps":' + (ConvertTo-JsonArray $apps) + ',"p_searches":' + (ConvertTo-JsonArray $searches) + '}'
  $result = Invoke-AgentRpc $Config 'agent_report_usage' $null $json
  Save-SearchCursors $batch.cursors
  $queue.activeSeconds = 0
  $queue.apps = @()
  Save-ActivityQueue $queue
  Write-AgentLog ("Usage report: " + $result.active_seconds + " active seconds, " + $result.apps + " apps, " + $result.searches + " searches.")
}

function Ensure-SampleTask {
  try { $user = [string](Get-AgentConfig).windows_user } catch { return }
  if (-not $user) { return }
  $tr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\MulkAgent\MulkAgent.ps1 -Sample'
  & schtasks.exe /Create /TN 'Mulk Agent Sample' /SC MINUTE /MO 5 /RU $user /IT /RL LIMITED /TR $tr /F | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-AgentLog 'The activity sample could not be scheduled. Leave the Mulk Agent window open so active time is still counted.'
  }
}

function Json-Text($Value) {
  if ($null -eq $Value) { return 'null' }
  $text = [string]$Value
  if ($text.Length -gt 500) { $text = $text.Substring(0, 500) }
  return ConvertTo-Json -InputObject $text -Compress
}

function Json-Number($Value) {
  if ($null -eq $Value -or $Value -eq '') { return 'null' }
  return (([string]$Value) -replace ',', '.')
}

function Get-HealthReport {
  $report = @{
    manufacturer = ''; model = ''; serial = ''
    ram = $null; disk = $null; free = $null
    bitlocker = 'unknown'; defender = 'unknown'; defenderAge = $null
    firewall = 'unknown'; reboot = $false; admins = ''; startup = ''
  }
  try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $report.manufacturer = [string]$cs.Manufacturer
    $report.model = [string]$cs.Model
    if ($cs.TotalPhysicalMemory) { $report.ram = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 1) }
  } catch { }
  try {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $report.serial = [string]$bios.SerialNumber
  } catch { }
  try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
    if ($disk.Size) { $report.disk = [math]::Round(($disk.Size / 1GB), 1) }
    if ($null -ne $disk.FreeSpace) { $report.free = [math]::Round(($disk.FreeSpace / 1GB), 1) }
  } catch { }
  try {
    $vol = Get-CimInstance -Namespace 'root\cimv2\security\microsoftvolumeencryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction Stop
    if ([int]$vol.ProtectionStatus -eq 1) { $report.bitlocker = 'on' }
    elseif ([int]$vol.ProtectionStatus -eq 0) { $report.bitlocker = 'off' }
  } catch { }
  try {
    $st = Get-MpComputerStatus -ErrorAction Stop
    $report.defender = $(if ([bool]$st.RealTimeProtectionEnabled -and [bool]$st.AntivirusEnabled) { 'on' } else { 'off' })
    if ($st.AntivirusSignatureLastUpdated) {
      $report.defenderAge = [int][math]::Floor(((Get-Date) - [datetime]$st.AntivirusSignatureLastUpdated).TotalHours)
    }
  } catch { }
  try {
    $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    if ($profiles.Count -gt 0) {
      $anyOff = $false
      foreach ($p in $profiles) { if (-not [bool]$p.Enabled) { $anyOff = $true } }
      $report.firewall = $(if ($anyOff) { 'off' } else { 'on' })
    }
  } catch { }
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $report.reboot = $true }
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $report.reboot = $true }
  try {
    $raw = & "$env:SystemRoot\System32\net.exe" localgroup Administrators 2>$null
    $names = @()
    $capture = $false
    foreach ($line in @($raw)) {
      if ($line -match '^-+$') { $capture = $true; continue }
      if (-not $capture) { continue }
      if ($line -match 'command completed') { break }
      $name = ([string]$line).Trim()
      if ($name) { $names += $name }
    }
    $report.admins = ((@($names | Select-Object -Unique) -join ', '))
  } catch { }
  try {
    $names = @()
    foreach ($path in @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )) {
      $item = Get-Item -Path $path -ErrorAction SilentlyContinue
      if (-not $item) { continue }
      foreach ($n in @($item.GetValueNames())) {
        if ($n -and $n -ne '(default)') { $names += [string]$n }
      }
    }
    $report.startup = ((@($names | Select-Object -Unique) -join ', '))
  } catch { }
  return $report
}

function Send-Health($Config) {
  $h = Get-HealthReport
  $reboot = $(if ($h.reboot) { 'true' } else { 'false' })
  $tokenJson = ConvertTo-Json -InputObject ([string]$Config.token) -Compress
  $json = '{"p_token":' + $tokenJson +
    ',"p_manufacturer":' + (Json-Text $h.manufacturer) +
    ',"p_model":' + (Json-Text $h.model) +
    ',"p_serial":' + (Json-Text $h.serial) +
    ',"p_ram_gb":' + (Json-Number $h.ram) +
    ',"p_disk_gb":' + (Json-Number $h.disk) +
    ',"p_disk_free_gb":' + (Json-Number $h.free) +
    ',"p_bitlocker":' + (Json-Text $h.bitlocker) +
    ',"p_defender":' + (Json-Text $h.defender) +
    ',"p_firewall":' + (Json-Text $h.firewall) +
    ',"p_defender_age_hours":' + (Json-Number $h.defenderAge) +
    ',"p_pending_reboot":' + $reboot +
    ',"p_local_admins":' + (Json-Text $h.admins) +
    ',"p_startup_names":' + (Json-Text $h.startup) + '}'
  Invoke-AgentRpc $Config 'agent_report_health' $null $json
  Write-AgentLog 'Health report sent. Files, the screen, and the keyboard were not collected.'
}

function Apply-PendingAdminPassword($Config) {
  $secret = Invoke-AgentRpc $Config 'agent_take_local_password' @{ p_token = [string]$Config.token }
  if (-not $secret) { return }
  $secret = [string]$secret
  $ok = $false
  $detail = 'Local Administrator password changed'
  try {
    $account = [ADSI]'WinNT://./Administrator,user'
    $account.SetPassword($secret)
    $ok = $true
  } catch {
    $detail = [string]$_.Exception.Message
    if ($secret -and $detail.Contains($secret)) { $detail = 'The password change failed.' }
    if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) }
  } finally {
    $secret = $null
  }
  Invoke-AgentRpc $Config 'agent_finish_local_password' @{
    p_token = [string]$Config.token
    p_ok = $ok
    p_detail = $detail
  }
  if ($ok) { Write-AgentLog 'Local Administrator password was changed. The password is not written here.' }
  else { Write-AgentLog 'Local Administrator password change failed. The password is not written here.' }
}

function Split-InstallArgs([string]$Text) {
  if (-not $Text) { return @() }
  return @($Text -split '\s+' | Where-Object { $_ })
}

function Invoke-PendingInstall($Config) {
  $job = Invoke-AgentRpc $Config 'agent_take_install' @{ p_token = [string]$Config.token }
  if (-not $job -or -not $job.id) { return }
  $name = [string]$job.name
  $url = [string]$job.source_url
  $extra = [string]$job.silent_args
  $ok = $false
  $detail = ''
  $file = $null
  try {
    if ($url -notmatch '^https://') { throw 'The installer link is not https.' }
    if ($url -match '^https://[^/\s]*@') { throw 'The installer link cannot contain a password.' }
    $ext = [IO.Path]::GetExtension(([uri]$url).AbsolutePath).ToLowerInvariant()
    if ($ext -notin @('.msi', '.exe')) { throw 'Only an MSI or EXE installer is accepted.' }
    if ($extra -match '[;&|`$<>]') { throw 'The silent arguments contain a character that is not allowed.' }
    $dir = Join-Path $Root 'installs'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ([guid]::NewGuid().ToString('N') + $ext)
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -TimeoutSec 900 -MaximumRedirection 0
    $len = (Get-Item -Path $file).Length
    if ($len -lt 1024) { throw 'The download is too small to be an installer.' }
    if ($len -gt 700MB) { throw 'The installer is larger than 700 MB.' }
    $extraArgs = Split-InstallArgs $extra
    if ($ext -eq '.msi') {
      $argList = @('/i', $file, '/qn', '/norestart') + $extraArgs
      $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $argList -Wait -PassThru
    } elseif ($extraArgs.Count -gt 0) {
      $proc = Start-Process -FilePath $file -ArgumentList $extraArgs -Wait -PassThru
    } else {
      $proc = Start-Process -FilePath $file -Wait -PassThru
    }
    $code = [int]$proc.ExitCode
    if ($code -eq 0) { $ok = $true; $detail = 'Installed' }
    elseif ($code -eq 3010 -or $code -eq 1641) { $ok = $true; $detail = 'Installed. Windows may ask for a restart.' }
    else { $detail = "Installer exited with code $code" }
  } catch {
    $detail = [string]$_.Exception.Message
    if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 240) }
  } finally {
    if ($file -and (Test-Path -Path $file)) { Remove-Item -Path $file -Force -ErrorAction SilentlyContinue }
  }
  Invoke-AgentRpc $Config 'agent_finish_install' @{
    p_token = [string]$Config.token
    p_job = [string]$job.id
    p_ok = $ok
    p_detail = $detail
  }
  Write-AgentLog ("Install " + $name + ": " + $detail)
}

$LockFlag = Join-Path $Root 'locked.flag'

function Initialize-LogonPolicy {
  if ('MulkLogonPolicy' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class MulkLogonPolicy {
  [StructLayout(LayoutKind.Sequential)]
  struct LSA_UNICODE_STRING {
    public ushort Length;
    public ushort MaximumLength;
    public IntPtr Buffer;
  }

  [StructLayout(LayoutKind.Sequential)]
  struct LSA_OBJECT_ATTRIBUTES {
    public int Length;
    public IntPtr RootDirectory;
    public IntPtr ObjectName;
    public uint Attributes;
    public IntPtr SecurityDescriptor;
    public IntPtr SecurityQualityOfService;
  }

  [DllImport("advapi32.dll", PreserveSig = true)]
  static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attributes, uint access, out IntPtr handle);

  [DllImport("advapi32.dll", PreserveSig = true)]
  static extern uint LsaAddAccountRights(IntPtr policy, IntPtr sid, LSA_UNICODE_STRING[] rights, uint count);

  [DllImport("advapi32.dll", PreserveSig = true)]
  static extern uint LsaRemoveAccountRights(IntPtr policy, IntPtr sid, bool allRights, LSA_UNICODE_STRING[] rights, uint count);

  [DllImport("advapi32.dll", PreserveSig = true)]
  static extern uint LsaEnumerateAccountRights(IntPtr policy, IntPtr sid, out IntPtr rights, out uint count);

  [DllImport("advapi32.dll")]
  static extern uint LsaFreeMemory(IntPtr buffer);

  [DllImport("advapi32.dll")]
  static extern uint LsaClose(IntPtr handle);

  [DllImport("advapi32.dll")]
  static extern uint LsaNtStatusToWinError(uint status);

  const uint POLICY_ALL_ACCESS = 0x000F0FFF;
  const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;

  static IntPtr OpenPolicy() {
    LSA_OBJECT_ATTRIBUTES attributes = new LSA_OBJECT_ATTRIBUTES();
    attributes.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
    IntPtr handle;
    uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, POLICY_ALL_ACCESS, out handle);
    if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
    return handle;
  }

  static LSA_UNICODE_STRING MakeString(string value) {
    LSA_UNICODE_STRING text = new LSA_UNICODE_STRING();
    text.Buffer = Marshal.StringToHGlobalUni(value);
    text.Length = (ushort)(value.Length * 2);
    text.MaximumLength = (ushort)((value.Length + 1) * 2);
    return text;
  }

  static void FreeString(LSA_UNICODE_STRING text) {
    if (text.Buffer != IntPtr.Zero) Marshal.FreeHGlobal(text.Buffer);
  }

  static void Check(uint status) {
    if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
  }

  public static bool HasRight(byte[] sid, string right) {
    IntPtr policy = OpenPolicy();
    IntPtr sidPtr = Marshal.AllocHGlobal(sid.Length);
    try {
      Marshal.Copy(sid, 0, sidPtr, sid.Length);
      IntPtr rights;
      uint count;
      uint status = LsaEnumerateAccountRights(policy, sidPtr, out rights, out count);
      if (status == STATUS_OBJECT_NAME_NOT_FOUND) return false;
      Check(status);
      try {
        int size = Marshal.SizeOf(typeof(LSA_UNICODE_STRING));
        for (int i = 0; i < count; i++) {
          IntPtr item = new IntPtr(rights.ToInt64() + (i * size));
          LSA_UNICODE_STRING text = (LSA_UNICODE_STRING)Marshal.PtrToStructure(item, typeof(LSA_UNICODE_STRING));
          string name = Marshal.PtrToStringUni(text.Buffer, text.Length / 2);
          if (string.Equals(name, right, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
      } finally {
        LsaFreeMemory(rights);
      }
    } finally {
      Marshal.FreeHGlobal(sidPtr);
      LsaClose(policy);
    }
  }

  public static void AddRight(byte[] sid, string right) {
    IntPtr policy = OpenPolicy();
    IntPtr sidPtr = Marshal.AllocHGlobal(sid.Length);
    LSA_UNICODE_STRING text = MakeString(right);
    try {
      Marshal.Copy(sid, 0, sidPtr, sid.Length);
      Check(LsaAddAccountRights(policy, sidPtr, new LSA_UNICODE_STRING[] { text }, 1));
    } finally {
      FreeString(text);
      Marshal.FreeHGlobal(sidPtr);
      LsaClose(policy);
    }
  }

  public static void RemoveRight(byte[] sid, string right) {
    IntPtr policy = OpenPolicy();
    IntPtr sidPtr = Marshal.AllocHGlobal(sid.Length);
    LSA_UNICODE_STRING text = MakeString(right);
    try {
      Marshal.Copy(sid, 0, sidPtr, sid.Length);
      uint status = LsaRemoveAccountRights(policy, sidPtr, false, new LSA_UNICODE_STRING[] { text }, 1);
      if (status == STATUS_OBJECT_NAME_NOT_FOUND) return;
      Check(status);
    } finally {
      FreeString(text);
      Marshal.FreeHGlobal(sidPtr);
      LsaClose(policy);
    }
  }
}
'@
}

function Get-SidBytes([string]$Sid) {
  $id = New-Object System.Security.Principal.SecurityIdentifier($Sid)
  $bytes = New-Object byte[] ($id.BinaryLength)
  $id.GetBinaryForm($bytes, 0)
  Write-Output $bytes -NoEnumerate
}

function Deny-InteractiveLogon {
  Initialize-LogonPolicy
  $rights = @('SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight')
  $sids = @('S-1-1-0')
  $added = New-Object System.Collections.Generic.List[string]
  foreach ($sid in $sids) {
    $bytes = Get-SidBytes $sid
    foreach ($right in $rights) {
      if (-not [MulkLogonPolicy]::HasRight($bytes, $right)) {
        [MulkLogonPolicy]::AddRight($bytes, $right)
        $added.Add($sid + '|' + $right)
      }
    }
  }
  return @($added)
}

function Allow-InteractiveLogon([string[]]$Pairs) {
  if (-not $Pairs) { return }
  Initialize-LogonPolicy
  foreach ($pair in @($Pairs)) {
    if ($pair -notmatch '^S-1-1-0\|SeDeny(Remote)?InteractiveLogonRight$') { continue }
    $sid, $right = $pair.Split('|')
    [MulkLogonPolicy]::RemoveRight((Get-SidBytes $sid), $right)
  }
}

function Read-LockFlag {
  if (-not (Test-Path $LockFlag)) { return $null }
  $info = @{ account = ''; rights = @() }
  foreach ($line in @(Get-Content -Path $LockFlag -ErrorAction SilentlyContinue)) {
    if ($line -like 'account=*') { $info.account = $line.Substring(8).Trim() }
    elseif ($line -like 'rights=*') {
      $info.rights = @($line.Substring(7).Split(';') | Where-Object { $_ })
    }
  }
  return $info
}

function Write-LockFlag([string]$Account, [string[]]$Rights) {
  $text = @('account=' + $Account, 'rights=' + ((@($Rights) | Where-Object { $_ }) -join ';'))
  Set-Content -Path $LockFlag -Value $text -Encoding UTF8
}

function Get-LocalLogonName([string]$Account) {
  if (-not $Account) { return $null }
  if ($Account -match '^(AzureAD\\|.*@)') { return $null }
  if ($Account -match '\\') {
    $domain, $name = $Account.Split('\', 2)
    if ($domain -ne '.' -and $domain.ToLower() -ne $env:COMPUTERNAME.ToLower() -and $domain.ToLower() -ne 'localhost') { return $null }
    return $name
  }
  return $Account
}

function Set-EnrolledLocalAccount([string]$Account, [bool]$Enabled) {
  $name = Get-LocalLogonName $Account
  if (-not $name -or $name -eq 'Administrator') { return $false }
  $out = & "$env:SystemRoot\System32\net.exe" user $name 2>&1 | Out-String
  if ($out -notmatch 'Account active') { return $false }
  $active = $out -match 'Account active\s+Yes'
  if ($Enabled) {
    if (-not $active) { & "$env:SystemRoot\System32\net.exe" user $name /active:yes | Out-Null }
    return $true
  }
  if ($active) {
    & "$env:SystemRoot\System32\net.exe" user $name /active:no | Out-Null
    return $true
  }
  return $false
}

function Enable-CompanyNetwork {
  $turnedOn = @()
  try {
    foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop)) {
      $blob = ([string]$adapter.Name) + ' ' + ([string]$adapter.InterfaceDescription)
      if ($blob -match 'Virtual|Hyper-V|VPN|Bluetooth|Loopback|Miniport|Teredo') { continue }
      $medium = [string]$adapter.NdisPhysicalMedium
      $lan = $medium -match '802\.3|802_11|Native802' -or $blob -match 'Ethernet|LAN|Wi-Fi|WiFi|WLAN|Wireless'
      if (-not $lan) { continue }
      if ([string]$adapter.Status -eq 'Disabled') {
        Enable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
        & "$env:SystemRoot\System32\netsh.exe" interface set interface name="$($adapter.Name)" admin=enabled | Out-Null
        $turnedOn += [string]$adapter.Name
      }
    }
  } catch {
    Write-AgentLog 'Network adapters could not be checked. Wi-Fi and Ethernet were not turned off.'
  }
  foreach ($name in @('WlanSvc', 'Dhcp', 'Dnscache', 'NlaSvc')) {
    try {
      $service = Get-Service -Name $name -ErrorAction SilentlyContinue
      if (-not $service) { continue }
      if ($service.StartType -eq 'Disabled') {
        $startup = 'Manual'
        if ($name -eq 'WlanSvc' -or $name -eq 'Dhcp') { $startup = 'Automatic' }
        Set-Service -Name $name -StartupType $startup -ErrorAction SilentlyContinue
        $turnedOn += $name
      }
      if ((Get-Service -Name $name).Status -ne 'Running') {
        Start-Service -Name $name -ErrorAction SilentlyContinue
      }
    } catch { }
  }
  if ($turnedOn.Count -gt 0) {
    Write-AgentLog ('Kept the dashboard connection on: ' + ($turnedOn -join ', ') + '. Wi-Fi and Ethernet are not turned off while this computer is locked.')
  }
}

function Stop-UserSessions {
  $lines = @(& "$env:SystemRoot\System32\query.exe" session 2>$null)
  foreach ($line in $lines) {
    $text = [string]$line
    if ($text -notmatch '\s(\d+)\s+(Active|Disc)') { continue }
    $id = [int]$Matches[1]
    if ($id -le 0) { continue }
    if ($text -match 'services') { continue }
    & "$env:SystemRoot\System32\logoff.exe" $id 2>$null | Out-Null
  }
}

function Set-LockNotice([bool]$Locked, [string]$Reason) {
  $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  try {
    if ($Locked) {
      $text = 'This computer is locked by Mulk IT. You cannot sign in until an administrator unlocks it. Wi-Fi and Ethernet stay connected.'
      if ($Reason) { $text = $text + ' ' + $Reason }
      if ($text.Length -gt 400) { $text = $text.Substring(0, 400) }
      if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
      New-ItemProperty -Path $key -Name legalnoticecaption -Value 'Locked by IT' -PropertyType String -Force | Out-Null
      New-ItemProperty -Path $key -Name legalnoticetext -Value $text -PropertyType String -Force | Out-Null
    } else {
      $caption = (Get-ItemProperty -Path $key -Name legalnoticecaption -ErrorAction SilentlyContinue).legalnoticecaption
      if ($caption -eq 'Locked by IT') {
        Remove-ItemProperty -Path $key -Name legalnoticecaption -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $key -Name legalnoticetext -ErrorAction SilentlyContinue
      }
    }
  } catch {
    Write-AgentLog 'The sign-in notice could not be updated.'
  }
}

function Sync-AssetLock($policy) {
  Set-LockNotice $false ''
  $existing = Read-LockFlag
  if (-not $existing) { return }
  Allow-InteractiveLogon $existing.rights
  if ($existing.account) { Set-EnrolledLocalAccount $existing.account $true | Out-Null }
  Remove-Item -Path $LockFlag -Force -ErrorAction SilentlyContinue
  & schtasks.exe /Delete /TN 'Mulk Agent Lock' /F 2>$null | Out-Null
  Write-AgentLog 'Sign-in lock was removed. This computer no longer blocks sign-in.'
}

function Ensure-WatchTask {
  $tr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\MulkAgent\MulkAgent.ps1 -Watch'
  & schtasks.exe /Create /TN 'Mulk Agent Watch' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $tr /F | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-AgentLog 'The dashboard check could not be scheduled. The five-minute check still runs.'
  }
}

function Start-QuickAssist {
  $qa = Join-Path $env:SystemRoot 'System32\quickassist.exe'
  if (Test-Path $qa) { Start-Process -FilePath $qa | Out-Null }
  else { Start-Process 'ms-quick-assist:' | Out-Null }
}

function Ask-RemoteApproval {
  if ($script:supportPrompt) { return }
  $config = Get-AgentConfig
  try {
    $policy = Get-Policy $config
  } catch { return }
  $job = Invoke-AgentRpc $config 'agent_take_support' @{ p_token = [string]$config.token }
  if (-not $job -or -not $job.id) { return }
  $code = [string]$job.assist_code
  $script:supportPrompt = $true
  $ok = $false
  $detail = 'The person declined. Nothing was opened.'
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $answer = [System.Windows.Forms.MessageBox]::Show(
      "IT wants to connect to this computer with Windows Quick Assist.`r`n`r`nYou will see the Quick Assist window. The screen is not saved, and the keyboard is not recorded.`r`n`r`nAllow this connection?",
      'Mulk Agent',
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
      $detail = 'The person declined. Nothing was opened.'
    } else {
      if ($code) {
        [System.Windows.Forms.MessageBox]::Show(
          "Allowed. In the Quick Assist window, enter this code: $code`r`n`r`nThe screen is not saved.",
          'Mulk Agent'
        ) | Out-Null
      }
      Start-QuickAssist
      $ok = $true
      $detail = 'The person allowed it. Quick Assist opened. The screen is not saved.'
    }
  } catch {
    $detail = [string]$_.Exception.Message
    if ($code -and $detail.Contains($code)) { $detail = 'Remote support could not open.' }
    if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 240) }
  } finally {
    $code = ''
    $script:supportPrompt = $false
  }
  Invoke-AgentRpc $config 'agent_finish_support' @{
    p_token = [string]$config.token
    p_job = [string]$job.id
    p_ok = $ok
    p_detail = $detail
  }
  if ($ok) { Write-AgentLog 'The person allowed remote support. Quick Assist opened. The screen is not saved and the keyboard is not recorded.' }
  else { Write-AgentLog $detail }
}

function Invoke-Watch {
  $config = $null
  try { $config = Get-AgentConfig } catch {
    Write-AgentLog ('Dashboard check could not read this computer: ' + $_.Exception.Message)
    return
  }
  try { Sync-AssetLock $null } catch { Write-AgentLog 'Could not clear an old sign-in lock.' }
  try {
    Get-Policy $config | Out-Null
    try { Update-LeftOnSystem $config } catch { Write-AgentLog ('Shutdown reminder failed: ' + $_.Exception.Message) }
  } catch {
    Write-AgentLog ('Dashboard check could not reach the dashboard: ' + $_.Exception.Message)
  }
}

function Invoke-Enforce {
  $config = Get-AgentConfig
  $policy = Get-Policy $config
  $user = [string]$policy.windows_user
  if (-not $user) { $user = [string]$config.windows_user }
  try { Protect-AgentStore $user } catch { Write-AgentLog ('Could not tighten the agent folder permissions.') }
  try { Sync-AssetLock $policy } catch { Write-AgentLog 'Could not clear an old sign-in lock.' }
  try { Ensure-WatchTask } catch { Write-AgentLog ('Dashboard check schedule failed: ' + $_.Exception.Message) }
  $grant = ($policy.admin -eq 'elevated' -or $policy.admin -eq 'standing') -and -not [bool]$policy.hold
  Set-LocalAdmin $user $grant
  $usb = [string]$policy.usb
  if ([bool]$policy.hold) { $usb = 'block' }
  if ($usb -notin @('block', 'read', 'allow')) { $usb = 'block' }
  Set-UsbPolicy $usb
  try { Apply-PendingAdminPassword $config } catch { Write-AgentLog 'Password change failed before it could be confirmed. The password is not written here.' }
  try { Invoke-PendingInstall $config } catch { Write-AgentLog ("Install failed: " + $_.Exception.Message) }
  try { Send-Presence $config } catch { Write-AgentLog ("Location report failed: " + $_.Exception.Message) }
  try { Ensure-SampleTask } catch { Write-AgentLog ("Activity schedule failed: " + $_.Exception.Message) }
  if (Test-Due 'inventory' 120) {
    $heavyOk = $true
    try { Send-SoftwareInventory $config } catch { $heavyOk = $false; Write-AgentLog ("Software report failed: " + $_.Exception.Message) }
    try { Send-Health $config } catch { $heavyOk = $false; Write-AgentLog ("Health report failed: " + $_.Exception.Message) }
    try { Send-UsbNotices $config $policy } catch { $heavyOk = $false; Write-AgentLog ("USB report failed: " + $_.Exception.Message) }
    try { Send-Usage $config } catch { $heavyOk = $false; Write-AgentLog ("Usage report failed: " + $_.Exception.Message) }
    if ($heavyOk) { Mark-Done 'inventory' }
  }
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

if ($Watch) {
  Invoke-Watch
  exit 0
}

if ($Sample) {
  try { Ask-RemoteApproval } catch { Write-AgentLog ('Remote support failed: ' + $_.Exception.Message) }
  try { Add-ActivitySample } catch {
    Write-AgentLog ("Activity sample failed: " + $_.Exception.Message)
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
$form.Size = New-Object System.Drawing.Size(520, 900)
$form.MinimumSize = New-Object System.Drawing.Size(480, 820)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.BackColor = [System.Drawing.Color]::FromArgb(244, 245, 247)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Mulk Agent'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 16)
$form.Controls.Add($title)

$intro = New-Object System.Windows.Forms.Label
$intro.Text = 'This window is the company agent for this computer. It reports installed programs, computer health, USB device names, the city and country of the public IP, web search text, active time, and which app is in front. IT can set the local Administrator password once. A company installer runs only when IT sends it to several computers from Bulk install. It does not lock sign-in. If this computer is left running after office hours, 8:00 AM to 6:00 PM, you will be reminded to shut it down the next time you use it. If you ask for remote help, IT can connect only after you choose Allow. Quick Assist then opens on this screen. The screen is not saved. It does not read files, capture the screen, record the keyboard, or use GPS.'
$intro.Size = New-Object System.Drawing.Size(460, 156)
$intro.Location = New-Object System.Drawing.Point(20, 52)
$form.Controls.Add($intro)

$status = New-Object System.Windows.Forms.Label
$status.Size = New-Object System.Drawing.Size(460, 88)
$status.Location = New-Object System.Drawing.Point(20, 216)
$form.Controls.Add($status)

$rules = New-Object System.Windows.Forms.ListBox
$rules.Size = New-Object System.Drawing.Size(460, 110)
$rules.Location = New-Object System.Drawing.Point(20, 310)
$form.Controls.Add($rules)

$nameLabel = New-Object System.Windows.Forms.Label
$nameLabel.Text = 'Your name'
$nameLabel.Location = New-Object System.Drawing.Point(20, 428)
$nameLabel.AutoSize = $true
$form.Controls.Add($nameLabel)

$nameBox = New-Object System.Windows.Forms.TextBox
$nameBox.Location = New-Object System.Drawing.Point(20, 450)
$nameBox.Size = New-Object System.Drawing.Size(460, 28)
$form.Controls.Add($nameBox)

$reasonLabel = New-Object System.Windows.Forms.Label
$reasonLabel.Text = 'Why you need admin rights'
$reasonLabel.Location = New-Object System.Drawing.Point(20, 486)
$reasonLabel.AutoSize = $true
$form.Controls.Add($reasonLabel)

$reasonBox = New-Object System.Windows.Forms.TextBox
$reasonBox.Location = New-Object System.Drawing.Point(20, 508)
$reasonBox.Size = New-Object System.Drawing.Size(460, 28)
$form.Controls.Add($reasonBox)

$ask = New-Object System.Windows.Forms.Button
$ask.Text = 'Request admin rights'
$ask.Location = New-Object System.Drawing.Point(20, 544)
$ask.Size = New-Object System.Drawing.Size(180, 34)
$form.Controls.Add($ask)

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = 'Refresh'
$refresh.Location = New-Object System.Drawing.Point(210, 544)
$refresh.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($refresh)

$helpLabel = New-Object System.Windows.Forms.Label
$helpLabel.Text = 'What do you need help with'
$helpLabel.Location = New-Object System.Drawing.Point(20, 588)
$helpLabel.AutoSize = $true
$form.Controls.Add($helpLabel)

$helpBox = New-Object System.Windows.Forms.TextBox
$helpBox.Location = New-Object System.Drawing.Point(20, 610)
$helpBox.Size = New-Object System.Drawing.Size(460, 28)
$form.Controls.Add($helpBox)

$help = New-Object System.Windows.Forms.Button
$help.Text = 'Request remote help'
$help.Location = New-Object System.Drawing.Point(20, 646)
$help.Size = New-Object System.Drawing.Size(180, 34)
$form.Controls.Add($help)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(20, 690)
$logBox.Size = New-Object System.Drawing.Size(460, 72)
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
    $network = 'Network location is sent to IT.'
    $cache = Join-Path $Root 'presence-cache.json'
    if (Test-Path $cache) {
      try {
        $geo = Get-Content -Path $cache -Raw -Encoding UTF8 | ConvertFrom-Json
        $network = ('Network: ' + [string]$geo.city + ', ' + [string]$geo.country_code + ' · ' + [string]$geo.ip).Trim()
      } catch { }
    }
    $status.Text = @(
      ([string]$policy.tag + '  ' + [string]$policy.description),
      $adminText,
      $holdText,
      $network
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
$help.Add_Click({
  try {
    $who = $nameBox.Text.Trim()
    $why = $helpBox.Text.Trim()
    if ($who.Length -lt 2) { throw 'Enter your name.' }
    if ($why.Length -lt 8) { throw 'Write what you need help with, at least a few words.' }
    $config = Get-AgentConfig
    Invoke-AgentRpc $config 'agent_request_support' @{ p_token = $config.token; p_requested_by = $who; p_reason = $why }
    $helpBox.Text = ''
    Write-AgentLog "Remote help requested for $who."
    [System.Windows.Forms.MessageBox]::Show('Request sent. IT will see it on the dashboard. Nothing connects until you choose Allow.', 'Mulk Agent')
    Update-LogView
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Mulk Agent')
  }
})
$script:supportPrompt = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300000
$timer.Add_Tick({
  try { Add-ActivitySample } catch { }
  try { Ask-RemoteApproval } catch { }
  Update-Window
})
$timer.Start()
$form.Add_Shown({
  Update-Window
  try { Update-Unattended } catch { }
  try { Ask-RemoteApproval } catch { }
})
[void]$form.ShowDialog()
$timer.Stop()
$mutex.ReleaseMutex() | Out-Null
