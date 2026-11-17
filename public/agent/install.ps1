# Installs Mulk Agent on this Windows computer. Run it from an Administrator PowerShell.
# The checks run quietly. The window opens only from the tray icon.
param(
  [string]$Code,
  [string]$WindowsUser,
  [string]$Origin = 'https://mulk-asset-manager.vercel.app'
)
# $Code is ignored. A new computer waits in Control until an admin assigns it to an asset.

$ErrorActionPreference = 'Stop'
$Root = 'C:\ProgramData\MulkAgent'
$Origin = $Origin.TrimEnd('/')

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  Write-Host 'Run this setup as Administrator. Right-click PowerShell, then Run as administrator.'
  exit 1
}

if (-not $WindowsUser) {
  $current = whoami
  $WindowsUser = Read-Host "Windows account to manage [$current]"
  if (-not $WindowsUser) { $WindowsUser = $current }
}

New-Item -ItemType Directory -Force -Path $Root | Out-Null
$agentFile = Join-Path $Root 'MulkAgent.ps1'
Invoke-WebRequest -Uri ($Origin + '/agent/MulkAgent.ps1') -OutFile $agentFile -UseBasicParsing

$configRes = Invoke-WebRequest -Uri ($Origin + '/api/config') -UseBasicParsing
$public = $configRes.Content | ConvertFrom-Json
if (-not $public.supabaseUrl -or -not $public.supabaseAnonKey) {
  throw 'The asset app is not connected to its database yet.'
}

$headers = @{
  apikey = $public.supabaseAnonKey
  Authorization = 'Bearer ' + $public.supabaseAnonKey
  'Content-Type' = 'application/json'
}
$accounts = @()
try {
  $skip = @('Guest', 'DefaultAccount', 'WDAGUtilityAccount')
  $signedIn = ($WindowsUser.Trim() -split '\\')[-1]
  $accounts = @(Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND Disabled=False" |
    ForEach-Object { [string]$_.Name } |
    Where-Object { $_ -and ($_ -notin $skip) -and ($_ -ne $signedIn) } |
    Select-Object -First 12)
} catch { $accounts = @() }
$accountText = ($accounts -join ', ')
if ($accountText.Length -gt 400) { $accountText = $accountText.Substring(0, 400) }
$body = @{ p_hostname = $env:COMPUTERNAME; p_windows_user = $WindowsUser.Trim(); p_accounts = $accountText } | ConvertTo-Json -Compress
try {
  $enroll = Invoke-WebRequest -Uri ($public.supabaseUrl.TrimEnd('/') + '/rest/v1/rpc/agent_register') -Method Post -Headers $headers -Body $body -UseBasicParsing
} catch {
  $detail = $_.Exception.Message
  if ($_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
  throw "Could not register this computer. $detail"
}
$result = $enroll.Content | ConvertFrom-Json

$device = @{
  url = $public.supabaseUrl
  anon = $public.supabaseAnonKey
  token = $result.token
  windows_user = $result.windows_user
}
$devicePath = Join-Path $Root 'device.json'
$device | ConvertTo-Json | Set-Content -Path $devicePath -Encoding UTF8

function Set-LockedAcl([string]$Path, [bool]$UsersCanAppend) {
  $acl = Get-Acl -Path $Path
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
  $system = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')).Translate([System.Security.Principal.NTAccount])
  $admins = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount])
  $users = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([System.Security.Principal.NTAccount])
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, 'FullControl', 'Allow')))
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, 'FullControl', 'Allow')))
  $userRight = if ($UsersCanAppend) { 'Modify' } else { 'ReadAndExecute' }
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, $userRight, 'Allow')))
  Set-Acl -Path $Path -AclObject $acl
}

Set-LockedAcl $agentFile $false
Set-LockedAcl $devicePath $false
New-Item -ItemType File -Force -Path (Join-Path $Root 'agent.log') | Out-Null
Set-LockedAcl (Join-Path $Root 'agent.log') $true

@'
If WScript.Arguments.Count = 0 Then WScript.Quit 1
mode = WScript.Arguments(0)
sta = ""
If mode = "Tray" Or mode = "Show" Then sta = "-STA "
ps = "powershell.exe -NoProfile " & sta & "-WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\ProgramData\MulkAgent\MulkAgent.ps1"" -" & mode
CreateObject("Wscript.Shell").Run ps, 0, False
'@ | Set-Content -Path (Join-Path $Root 'run-hidden.vbs') -Encoding ASCII

$startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp\Mulk Agent.lnk'
if (Test-Path $startup) { Remove-Item $startup -Force }
$menu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Mulk Agent.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($menu)
$link.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$link.Arguments = '//B //Nologo C:\ProgramData\MulkAgent\run-hidden.vbs Show'
$link.WorkingDirectory = $Root
$link.WindowStyle = 7
$link.Description = 'Open Mulk Agent'
$link.Save()

$launch = 'wscript.exe //B //Nologo C:\ProgramData\MulkAgent\run-hidden.vbs'
schtasks.exe /Create /TN 'Mulk Agent Enforce' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR "$launch Enforce" /F | Out-Null
schtasks.exe /Create /TN 'Mulk Agent Watch' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR "$launch Watch" /F | Out-Null
schtasks.exe /Create /TN 'Mulk Agent Sample' /SC MINUTE /MO 5 /RU $WindowsUser /IT /RL LIMITED /TR "$launch Sample" /F | Out-Null
schtasks.exe /Create /TN 'Mulk Agent Tray' /SC ONLOGON /RU $WindowsUser /IT /RL LIMITED /TR "$launch Tray" /F | Out-Null

Write-Host "Mulk Agent installed on $($result.hostname) for $($result.windows_user)."
Write-Host 'It stays quiet. Open it from the up arrow at the bottom right of the taskbar when support is needed.'
Write-Host 'It stays pending until an admin assigns it to an asset in Control.'
Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList '//B','//Nologo',(Join-Path $Root 'run-hidden.vbs'),'Tray' -WindowStyle Hidden
Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList '//B','//Nologo',(Join-Path $Root 'run-hidden.vbs'),'Enforce' -WindowStyle Hidden
