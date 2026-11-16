# Mulk Agent. A visible company program for one Windows computer.
# It shows the rules, sends an admin request, and applies the decision IT approved.
# It reports installed programs, USB devices, the public IP city/country,
# web searches, active time, and which app is in front.
# It does not record keystrokes, screenshots, documents, page contents, or GPS.
param(
  [switch]$Enforce,
  [switch]$Sample
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
  & schtasks.exe /Create /TN 'Mulk Agent Sample' /SC MINUTE /MO 1 /RU $user /IT /RL LIMITED /TR $tr /F | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-AgentLog 'The one-minute activity sample could not be scheduled. Leave the Mulk Agent window open so active time is still counted.'
  }
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
  try { Send-Presence $config } catch { Write-AgentLog ("Location report failed: " + $_.Exception.Message) }
  try { Ensure-SampleTask } catch { Write-AgentLog ("Activity schedule failed: " + $_.Exception.Message) }
  try { Send-Usage $config } catch { Write-AgentLog ("Usage report failed: " + $_.Exception.Message) }
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

if ($Sample) {
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
$form.Size = New-Object System.Drawing.Size(520, 740)
$form.MinimumSize = New-Object System.Drawing.Size(480, 660)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.BackColor = [System.Drawing.Color]::FromArgb(244, 245, 247)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Mulk Agent'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 16)
$form.Controls.Add($title)

$intro = New-Object System.Windows.Forms.Label
$intro.Text = 'This window is the company agent for this computer. It reports installed programs, USB devices, the city and country of the public IP, web searches, active time, and which app is in front. It does not read page contents, passwords, documents, keystrokes, screenshots, or GPS.'
$intro.Size = New-Object System.Drawing.Size(460, 72)
$intro.Location = New-Object System.Drawing.Point(20, 52)
$form.Controls.Add($intro)

$status = New-Object System.Windows.Forms.Label
$status.Size = New-Object System.Drawing.Size(460, 96)
$status.Location = New-Object System.Drawing.Point(20, 132)
$form.Controls.Add($status)

$rules = New-Object System.Windows.Forms.ListBox
$rules.Size = New-Object System.Drawing.Size(460, 130)
$rules.Location = New-Object System.Drawing.Point(20, 236)
$form.Controls.Add($rules)

$nameLabel = New-Object System.Windows.Forms.Label
$nameLabel.Text = 'Your name'
$nameLabel.Location = New-Object System.Drawing.Point(20, 378)
$nameLabel.AutoSize = $true
$form.Controls.Add($nameLabel)

$nameBox = New-Object System.Windows.Forms.TextBox
$nameBox.Location = New-Object System.Drawing.Point(20, 400)
$nameBox.Size = New-Object System.Drawing.Size(460, 28)
$form.Controls.Add($nameBox)

$reasonLabel = New-Object System.Windows.Forms.Label
$reasonLabel.Text = 'Why you need admin rights'
$reasonLabel.Location = New-Object System.Drawing.Point(20, 436)
$reasonLabel.AutoSize = $true
$form.Controls.Add($reasonLabel)

$reasonBox = New-Object System.Windows.Forms.TextBox
$reasonBox.Location = New-Object System.Drawing.Point(20, 458)
$reasonBox.Size = New-Object System.Drawing.Size(460, 28)
$form.Controls.Add($reasonBox)

$ask = New-Object System.Windows.Forms.Button
$ask.Text = 'Request admin rights'
$ask.Location = New-Object System.Drawing.Point(20, 498)
$ask.Size = New-Object System.Drawing.Size(180, 34)
$form.Controls.Add($ask)

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = 'Refresh'
$refresh.Location = New-Object System.Drawing.Point(210, 498)
$refresh.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($refresh)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(20, 546)
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
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({
  try { Add-ActivitySample } catch { }
  Update-Window
})
$timer.Start()
$form.Add_Shown({ Update-Window })
[void]$form.ShowDialog()
$timer.Stop()
$mutex.ReleaseMutex() | Out-Null
