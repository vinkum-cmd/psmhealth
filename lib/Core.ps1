# Core.ps1 - everything except the RDP session itself: environment, CSV rules, alert state, lock, pause, history, cleanup, pre-checks,
# validation, report + mail, the run flow. No sessions are opened and no passwords are handled here (so it can be self-tested anywhere).
# Dot-sourced by Run-PsmTests.ps1. Config files are only READ (ConvertFrom-Json / Import-Csv), never executed.

$script:StepNames = 'ccp', 'logon', 'account', 'connect', 'session', 'recording'
$script:StepLabel = @{ ccp = 'CCP password'; logon = 'REST logon'; account = 'Target account'; connect = 'PSMConnect'; session = 'RDP session'; recording = 'Recording' }
if (-not $script:HostName) { $script:HostName = $env:COMPUTERNAME }
if (-not $script:ToolVersion) { $script:ToolVersion = 'dev' }

function Read-Json($p) { if (Test-Path -LiteralPath $p) { Get-Content -Raw -LiteralPath $p | ConvertFrom-Json } else { $null } }
function Cfg($obj, [string]$path, $default) {
  $o = $obj
  foreach ($k in $path.Split('.')) { if ($null -eq $o) { return $default }; $p = $o.PSObject.Properties[$k]; if (-not $p) { return $default }; $o = $p.Value }
  if ($null -eq $o) { $default } else { $o }
}
function Get-PsmHome { if ($env:PSMT_HOME) { $env:PSMT_HOME } else { $script:ToolRoot } }
function Write-JsonFile([string]$Path, $Obj) { $tmp = "$Path.tmp"; $Obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8; Move-Item -LiteralPath $tmp -Destination $Path -Force }

# ------------------------------------------------------------------ -Trace: detailed per-row trace file (off by default). NEVER pass passwords, tokens, headers, request bodies or CCP answers to Write-Trace.
$script:TraceOn = $false; $script:TraceFile = $null
function Write-Trace([string]$Msg) {
  if (-not $script:TraceOn -or -not $script:TraceFile) { return }
  try { Add-Content -LiteralPath $script:TraceFile -Value ("[{0:HH:mm:ss.fff}] {1}" -f (Get-Date), $Msg) -Encoding UTF8 } catch { }
}

# ------------------------------------------------------------------ environment (envs\<name>\env.json + tests.csv + logs + results)
function Get-EnvName([string]$Arg) {
  if ($Arg) { return $Arg }
  if ($env:PSMT_ENV) { return $env:PSMT_ENV }
  $d = @(Get-ChildItem -LiteralPath (Join-Path (Get-PsmHome) 'envs') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'example' })
  if ($d.Count -eq 1) { return $d[0].Name }
  return ''
}
function Load-Environment([string]$Name) {
  $home_ = Get-PsmHome
  if (-not $Name) { throw 'no environment selected: use -Environment <name> (folders under envs\, besides example)' }
  if ($Name -notmatch '^[A-Za-z0-9_-]{1,32}$') { throw "environment name '$Name' not allowed (letters, digits, _ -)" }
  $base = Join-Path (Join-Path $home_ 'envs') $Name; $conf = Join-Path $base 'env.json'
  if (-not (Test-Path -LiteralPath $conf)) { throw "environment '$Name' not found: $conf$(if ($env:PSMT_ENV -eq $Name) { ' - this PowerShell window has PSMT_ENV set to it; remove it with: Remove-Item Env:PSMT_ENV' })" }
  $settings = Read-Json $conf
  $mail = if ($settings.PSObject.Properties['mail']) { $settings.mail } else { Read-Json (Join-Path $base 'mail.env.json') }
  $logs = Join-Path $base 'logs'; $res = Join-Path $base 'results'
  New-Item -ItemType Directory -Force -Path $logs, $res | Out-Null
  @{ Name = $Name; Base = $base; Settings = $settings; Mail = $mail; Tests = (Join-Path $base 'tests.csv'); Logs = $logs; Results = $res }
}
# the reason sent to CCP and PVWA (it appears in their audit logs): the configured text + the day and time, so every audit entry can be matched to a test run
function Get-RunReason([string]$Base, $When = (Get-Date)) { '{0} on {1}' -f $Base, $When.ToString('dddd yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
function Set-RunVars($Settings, $Mail) {
  $script:Settings = $Settings; $script:MailCfg = $Mail
  $script:HoldSec = [int](Cfg $Settings 'test.hold_seconds' 150)
  $script:RecWait = [int](Cfg $Settings 'test.recording_wait_seconds' 120)
  $script:RecCheck = [bool](Cfg $Settings 'test.check_recording' $true)
  $script:MinPct = [int](Cfg $Settings 'test.min_recording_percent' 0)
  $script:TitleCheck = [bool](Cfg $Settings 'test.check_window_titles' $true)
  $script:Reason = [string](Cfg $Settings 'test.reason' 'automated psm health test')
  $script:TitlesErr = @(Cfg $Settings 'window_titles.error_anywhere' @('Dispatcher error message', 'Fatal Error'))
  $script:TitlesLast = @(Cfg $Settings 'window_titles.error_if_last' @('Warning', 'Security Alert'))
  $script:Allowed = @(Cfg $Settings 'allowed_components' @('PSM-RDP', 'PSM-SSH', 'PSM-WinScp', 'WINSCP-SSH'))
  $script:Prefix = [string](Cfg $Mail 'subject_prefix' '[PSM health]')
  $script:KeepDays = [int](Cfg $Settings 'outputs.keep_days' 30); $sk = Cfg $Settings 'outputs.screenshot_keep_days' $null; $script:ShotKeepDays = $(if ($null -ne $sk -and "$sk" -ne '') { [int]$sk } else { $script:KeepDays })
  $script:ShotMode = ([string](Cfg $Settings 'screenshots.mode' 'off')).ToLower(); if (@('off', 'failures', 'all') -notcontains $script:ShotMode) { $script:ShotMode = 'off' }
  $script:ShotEvery = [math]::Max(2, [int](Cfg $Settings 'screenshots.interval_sec' 5)); $script:ShotMailKb = [int](Cfg $Settings 'screenshots.max_mail_kb' 3000)
}


# ------------------------------------------------------------------ CSV input (validated; nothing is executed)
$script:ColMap = @{
  targetpsmserver = 'PSM_HOST,0'; targetccpurl = 'CCP_URL,1'; targetpvwaurl = 'PVWA,1'; psmenduser = 'PSM_USER,1'; endusersafe = 'CP_SAFE,1'
  enduserappid = 'CP_APPID,1'; enduserobjectname = 'CP_OBJECT,1'; enduserauthenticationmethod = 'AUTH_METHOD,1'; connectioncomponent = 'COMPONENT,1'
  targetaccount = 'ACCT_USER,1'; targetaccountaddress = 'ACCT_ADDR,0'; targetaccountsafe = 'ACCT_SAFE,1'; targetaccountid = 'ACCT_ID,0'; targetserver = 'TARGET_HOST,0'
  dismisspromptaftersec = 'PROMPT_AFTER,0'; dismisspromptcount = 'PROMPT_COUNT,0'; dismisspromptkey = 'PROMPT_KEY,0'
  holdsec = 'WAIT,0'; expectedtitle = 'TITLE_EXPECT,0'; retries = '_RETRIES,0'; enabled = '_ENABLED,0'
}
# the standard result columns (always present in results and mail, filled with the values a row really ran with)
$script:StdCols = @(@('TargetPSMServer', 'PSM_HOST'), @('TargetCCPUrl', 'CCP_URL'), @('TargetPVWAUrl', 'PVWA'), @('PSMEnduser', 'PSM_USER'), @('EndUserSafe', 'CP_SAFE'),
  @('EndUserApp-ID', 'CP_APPID'), @('EndUserObjectName', 'CP_OBJECT'), @('EndUser-Authentication-Method', 'AUTH_METHOD'), @('Connection-Component', 'COMPONENT'),
  @('TargetAccount', 'ACCT_USER'), @('TargetAccountAddress', 'ACCT_ADDR'), @('TargetAccountSafe', 'ACCT_SAFE'), @('TargetAccountID', 'ACCT_ID'), @('TargetServer', 'TARGET_HOST'))
$script:AuthOk = @{ ldap = 'LDAP'; cyberark = 'Cyberark'; radius = 'RADIUS'; windows = 'Windows' }
function Norm([string]$h) { ($h.ToLower() -replace '[^a-z0-9]', '') }
function Fix-Url([string]$v) { $v = $v.Trim(); if ($v.StartsWith('https://')) { $v } else { 'https://' + ($v -replace '^http://', '') } }

function Get-Defaults($Settings) {
  $pv = [string](Cfg $Settings 'pvwa_url' '')
  $d = @{ PSM_HOST = [string](Cfg $Settings 'defaults.psm_server' ''); CCP_URL = [string](Cfg $Settings 'enduser.ccp.url' $pv); PVWA = $pv
          PSM_USER = [string](Cfg $Settings 'enduser.name' ''); CP_SAFE = [string](Cfg $Settings 'enduser.ccp.safe' ''); CP_APPID = [string](Cfg $Settings 'enduser.ccp.app_id' '')
          CP_OBJECT = [string](Cfg $Settings 'enduser.ccp.object' ''); AUTH_METHOD = [string](Cfg $Settings 'enduser.auth_method' ''); ACCT_SAFE = [string](Cfg $Settings 'target.account_safe' '') }
  $o = @{}; foreach ($k in $d.Keys) { if ($d[$k]) { $o[$k] = $d[$k] } }; $o
}

function Read-Rows([string]$Path, $Settings) {
  $allowed = @(Cfg $Settings 'allowed_components' @('PSM-RDP', 'PSM-SSH', 'PSM-WinScp', 'WINSCP-SSH'))
  $defaults = Get-Defaults $Settings
  $data = @(Import-Csv -LiteralPath $Path)
  if ($data.Count -eq 0) { throw 'CSV has no rows' }
  $props = $data[0].PSObject.Properties.Name
  $unknown = @($props | Where-Object { -not $script:ColMap.ContainsKey((Norm $_)) })
  if ($unknown) { throw "CSV: unknown column(s) $($unknown -join ', ') - refusing to run" }
  $n = 0; $rows = @()
  foreach ($d in $data) {
    $n++; $e = @{}; $err = ''; $vals = @{}
    foreach ($p in $props) { $vals[(Norm $p)] = ([string]$d.$p).Trim() }
    foreach ($k in $script:ColMap.Keys) {
      $var, $req = $script:ColMap[$k].Split(','); $v = if ($vals.ContainsKey($k)) { $vals[$k] } else { '' }
      if ($v -notmatch '^[A-Za-z0-9._:@/\- ]*$') { $err = "column ${k}: characters not allowed"; break }
      if ($v -eq '' -and $defaults.ContainsKey($var) -and -not ($var -eq 'ACCT_SAFE' -and $vals['targetaccountid'])) { $v = $defaults[$var] }
      if ($req -eq '1' -and $v -eq '' -and -not (($var -eq 'ACCT_USER' -or $var -eq 'ACCT_SAFE') -and $vals['targetaccountid'])) { $err = "column ${k}: required (no value and no default in env.json)"; break }
      if ($v -ne '') { $e[$var] = $v }
    }
    $retries = $null; $enabled = $true
    if (-not $err) {
      $e.PVWA = Fix-Url $e.PVWA; $e.CCP_URL = Fix-Url $e.CCP_URL
      if ($e.ContainsKey('ACCT_ID') -and $e.ACCT_ID -notmatch '^\d+_\d+$') { $err = 'TargetAccountID must look like 12_34 (digits, underscore, digits)' }
      $pd = Cfg $Settings "prompt_defaults.$($e.COMPONENT)" $null
      $pk = @{ PROMPT_AFTER = 'after_sec'; PROMPT_COUNT = 'count'; PROMPT_KEY = 'key' }; $pdef = @{ PROMPT_AFTER = 0; PROMPT_COUNT = 1; PROMPT_KEY = 'Enter' }
      foreach ($k in 'PROMPT_AFTER', 'PROMPT_COUNT', 'PROMPT_KEY') {            # connector profile fills what the row leaves blank
        if (-not $e.ContainsKey($k)) { $e[$k] = [string](Cfg $pd $pk[$k] $pdef[$k]) }
      }
      if ($e.PROMPT_AFTER -notmatch '^\d+$' -or [int]$e.PROMPT_AFTER -gt 120) { $err = 'DismissPromptAfterSec must be a whole number from 0 to 120' }
      elseif ($e.PROMPT_COUNT -notmatch '^\d+$' -or [int]$e.PROMPT_COUNT -lt 1 -or [int]$e.PROMPT_COUNT -gt 3) { $err = 'DismissPromptCount must be a whole number from 1 to 3' }
      elseif (@('Enter', 'Y', 'A') -cnotcontains $e.PROMPT_KEY) { $err = 'DismissPromptKey must be Enter, Y or A' }
      elseif ($e.ContainsKey('WAIT') -and ($e.WAIT -notmatch '^\d+$' -or [int]$e.WAIT -lt 10 -or [int]$e.WAIT -gt 900)) { $err = 'HoldSec must be a whole number from 10 to 900' }
      elseif ($e.ContainsKey('TITLE_EXPECT') -and $e.TITLE_EXPECT.Length -gt 80) { $err = 'ExpectedTitle is longer than 80 characters' }
      if (-not $err -and $e.ContainsKey('_RETRIES')) { if ($e._RETRIES -match '^[0-2]$') { $retries = [int]$e._RETRIES } else { $err = 'Retries must be 0, 1 or 2' } }
      if (-not $err -and $e.ContainsKey('_ENABLED')) { $ev = $e._ENABLED.ToLower(); if (@('yes', 'no', 'true', 'false', '1', '0') -notcontains $ev) { $err = 'Enabled must be yes or no' } else { $enabled = @('yes', 'true', '1') -contains $ev } }
      $e.Remove('_RETRIES'); $e.Remove('_ENABLED')
      if (-not $err) {
        $e.AUTH_METHOD = $script:AuthOk[$e.AUTH_METHOD.ToLower()]
        if (-not $e.AUTH_METHOD) { $err = 'authentication method must be LDAP, Cyberark, RADIUS or Windows' }
        elseif ($allowed -cnotcontains $e.COMPONENT) { $err = "component '$($e.COMPONENT)' is not in allowed_components" }
      }
    }
    $rows += [pscustomobject]@{ N = $n; Env = $e; Err = $err; Retries = $retries; Enabled = $enabled }
  }
  $rows
}
function Get-Effective($Row) { $o = [ordered]@{}; foreach ($c in $script:StdCols) { $o[$c[0]] = if ($Row.Env.ContainsKey($c[1])) { $Row.Env[$c[1]] } else { '' } }; $o }

# ------------------------------------------------------------------ alert state: per test status, consecutive fails, whether an alert went out
function Get-State([string]$Path) {
  $st = @{}
  if (Test-Path -LiteralPath $Path) {
    $j = Read-Json $Path
    if ($j) { foreach ($p in $j.PSObject.Properties) { $v = $p.Value; $st[$p.Name] = @{ status = [string]$v.status; fails = $(if ($v.PSObject.Properties['fails']) { [int]$v.fails } elseif ($v.status -eq 'FAIL') { 1 } else { 0 })
              alerted = $(if ($v.PSObject.Properties['alerted']) { [bool]$v.alerted } else { ($v.status -eq 'FAIL' -and [long]$v.sent -gt 0) }); sent = [long]$v.sent } } }
  }
  $st
}
function Decide-Alert($Prev, [bool]$Passed, [long]$Now, [long]$RepeatSecs, [int]$AlertAfter) {
  if (-not $Prev) { $Prev = @{ status = 'PASS'; fails = 0; alerted = $false; sent = 0 } }
  if ($Passed) { return @{ Kind = $(if ($Prev.alerted) { 'RECOVERED' } else { '' }); State = @{ status = 'PASS'; fails = 0; alerted = $Prev.alerted; sent = $Prev.sent } } }
  $fails = $Prev.fails + 1
  if (-not $Prev.alerted) { $kind = if ($fails -ge $AlertAfter) { 'FAILED' } else { '' } }
  else { $kind = if ($Now - $Prev.sent -ge $RepeatSecs) { 'STILL FAILING' } else { '' } }
  @{ Kind = $kind; State = @{ status = 'FAIL'; fails = $fails; alerted = $Prev.alerted; sent = $Prev.sent } }
}
function Mark-Sent($State, [string]$Kind, [long]$Now) {
  if ($Kind -eq 'FAILED' -or $Kind -eq 'STILL FAILING') { $State.alerted = $true; $State.sent = $Now }
  elseif ($Kind -eq 'RECOVERED') { $State.alerted = $false; $State.fails = 0; $State.sent = $Now }
}

# ------------------------------------------------------------------ run lock + kill switch (per environment)
function Get-Epoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Acquire-Lock([string]$Path, [int]$StaleMinutes) {
  for ($i = 0; $i -lt 2; $i++) {
    try {
      $fs = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      $b = [Text.Encoding]::ASCII.GetBytes("$script:HostName|$PID|$(Get-Epoch)"); $fs.Write($b, 0, $b.Length); $fs.Close()
      return @{ Ok = $true; Msg = '' }
    } catch [IO.IOException] {
      $owner = ''; try { $owner = (Get-Content -Raw -LiteralPath $Path).Trim() } catch { }
      try { $ts = [long]$owner.Split('|')[2] } catch { $ts = [DateTimeOffset]::new((Get-Item -LiteralPath $Path).LastWriteTimeUtc).ToUnixTimeSeconds() }
      if ((Get-Epoch) - $ts -lt $StaleMinutes * 60) { return @{ Ok = $false; Msg = "another run is active (lock ${Path}: $owner)" } }
      Remove-Item -LiteralPath $Path -Force
    }
  }
  @{ Ok = $false; Msg = "cannot take lock $Path" }
}
function Test-Paused([string]$Base) { Test-Path -LiteralPath (Join-Path $Base 'PAUSE') }
function Set-Pause([string]$Base, [bool]$On) {
  $p = Join-Path $Base 'PAUSE'
  if ($On) { "paused $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content -LiteralPath $p } elseif (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

# ------------------------------------------------------------------ history, cleanup, optional outputs (results only - no passwords, no tokens)
function Add-History([string]$Path, [string]$RunId, $JRows) {
  $rows = @($JRows | ForEach-Object { [pscustomobject][ordered]@{ Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); RunId = $RunId; Row = $_.Row; Component = $_.Component; PSMServer = $_.PSMServer
        Account = $_.Account; Result = $_.Result; FailedStep = $_.FailedStep; Seconds = $_.Seconds; RecordingSec = $_.RecordingSec; Attempts = $_.Attempts } })
  try { $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Append -Encoding UTF8 }
  catch {   # a history.csv with other columns (older version, hand edit): keep it aside and start a new one. Bookkeeping must never stop a health check.
    try {
      $aside = $Path -replace '\.csv$', ('-{0:yyyyMMdd-HHmmss}.old.csv' -f (Get-Date)); Move-Item -LiteralPath $Path -Destination $aside -Force
      $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
      Write-Host "WARNING: history.csv had other columns; it was kept as $aside and a new history.csv was started"
    } catch { Write-Host "WARNING: history could not be written: $($_.Exception.Message)" }
  }
}
# files older than their limit: screenshots (*.screen.jpg) use ShotDays, everything else KeepDays; a limit of 0 means "keep forever". These names are never deleted.
function Get-OldFiles($Dirs, [int]$KeepDays, [int]$ShotDays) {
  $keep = 'mail-state.json', 'history.csv', 'status.json', 'heartbeat-alert.json'; $now = Get-Date; $old = @()
  foreach ($d in $Dirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue)) {
      if ($keep -contains $f.Name) { continue }
      $days = if ($f.Name -like '*.screen.jpg') { $ShotDays } else { $KeepDays }
      if ($days -gt 0 -and $f.LastWriteTime -lt $now.AddDays(-$days)) { $old += $f }
    }
  }
  $old
}
function Get-CleanupDirs($E) { @($E.Results, (Join-Path $E.Logs 'runs'), (Join-Path $E.Logs 'failed')) }
function Remove-OldFiles($Dirs, [int]$KeepDays, [int]$ShotDays = -1) {
  if ($ShotDays -lt 0) { $ShotDays = $KeepDays }
  $n = 0; foreach ($f in @(Get-OldFiles $Dirs $KeepDays $ShotDays)) { try { Remove-Item -LiteralPath $f.FullName -Force; $n++ } catch { } }
  $n
}
function Show-CleanupPreview($E) {
  $old = @(Get-OldFiles (Get-CleanupDirs $E) $script:KeepDays $script:ShotKeepDays)
  Write-Host "Cleanup preview - NOTHING is deleted. Limits: logs/results $(if ($script:KeepDays -gt 0) { "$($script:KeepDays) days" } else { 'kept forever' }), screenshots $(if ($script:ShotKeepDays -gt 0) { "$($script:ShotKeepDays) days" } else { 'kept forever' })."
  foreach ($f in @($old | Sort-Object LastWriteTime | Select-Object -First 50)) { Write-Host ("  {0:yyyy-MM-dd}  {1,4} days  {2,7} KB  {3}" -f $f.LastWriteTime, [int]((Get-Date) - $f.LastWriteTime).TotalDays, [math]::Ceiling($f.Length / 1KB), $f.FullName.Substring($E.Base.Length).TrimStart('\')) }
  if ($old.Count -gt 50) { Write-Host "  ... and $($old.Count - 50) more" }
  $kb = [math]::Ceiling((($old | Measure-Object -Property Length -Sum).Sum) / 1KB)
  Write-Host "$($old.Count) file(s), $kb KB would be removed by the next run. Never removed: history.csv, status.json, mail-state.json, heartbeat-alert.json."
  0
}
function Send-Webhook([string]$Url, $Payload) {
  if ($Url -notmatch '^https?://') { return 'webhook url must start with http(s)://' }
  try { Invoke-RestMethod -Uri $Url -Method Post -Body ($Payload | ConvertTo-Json -Depth 4) -ContentType 'application/json' -TimeoutSec 10 | Out-Null; 'ok' } catch { "failed: $($_.Exception.Message)" }
}
function Write-EventLogEntry([string]$Msg) {   # optional; the source must be registered once by an admin: New-EventLog -LogName Application -Source PSMHealthTest
  try { Write-EventLog -LogName Application -Source PSMHealthTest -EventId 4000 -EntryType Information -Message $Msg } catch { }
}

# ------------------------------------------------------------------ pre-checks and validation (DNS + TCP only; IPv4 only; no logon)
function Get-Ipv4([string]$HostName_) {
  try { @([Net.Dns]::GetHostAddresses($HostName_) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) } catch { @() }
}
function Test-Tcp([string]$HostName_, [int]$Port, [int]$TimeoutMs = 4000) {
  $ip = @(Get-Ipv4 $HostName_); if (-not $ip) { return $false }      # @() : a one-address result is a plain string, and $ip[0] would be its first character
  $c = New-Object Net.Sockets.TcpClient
  try { $iar = $c.BeginConnect($ip[0], $Port, $null, $null); if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.EndConnect($iar); return $true }; return $false } catch { return $false } finally { $c.Close() }   # EndConnect throws when refused; Connected is only set by EndConnect
}
function Test-PsmServer([string]$HostName_, [int]$Port = 3389) {
  $ips = @(Get-Ipv4 $HostName_)
  if (-not $ips) { return @{ Ok = $false; Msg = "PSM server name '$HostName_' does not resolve in DNS" } }
  if (-not (Test-Tcp $HostName_ $Port)) { return @{ Ok = $false; Msg = "PSM server $HostName_ ($($ips -join ', ')) not reachable on TCP $Port" } }
  @{ Ok = $true; Msg = "$HostName_ -> $($ips -join ', ')" }
}
function Invoke-Validate($E, $Rows) {
  $bad = 0
  function Line([bool]$ok, [string]$what, [string]$extra = '') { Write-Host ("  [{0}] {1}{2}" -f $(if ($ok) { 'ok' } else { 'FAIL' }), $what, $(if ($extra) { " - $extra" } else { '' })); if (-not $ok) { $script:validateBad++ } }
  $script:validateBad = 0
  Write-Host "psm-test $script:ToolVersion  environment: $($E.Name)  tests: $($E.Tests)"
  Write-Host 'Host'
  Line ($PSVersionTable.PSVersion.Major -ge 5) "PowerShell $($PSVersionTable.PSVersion)"
  Line ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') 'STA thread (needed for the RDP window)' 'start with powershell.exe -STA -File ...'
  Line ($null -ne [Type]::GetTypeFromProgID('MsTscAx.MsTscAx')) 'RDP ActiveX control (MsTscAx)'
  Write-Host 'Test rows'
  foreach ($r in $Rows) { Line (-not $r.Err) "row $($r.N) $($r.Env.COMPONENT) $($r.Env.ACCT_USER)" ($r.Err + $(if (-not $r.Enabled) { '  (disabled)' } else { '' })) }
  Write-Host 'PSM servers (DNS + TCP 3389)'
  foreach ($h in @($Rows | Where-Object { $_.Enabled -and -not $_.Err -and $_.Env.PSM_HOST } | ForEach-Object { $_.Env.PSM_HOST } | Sort-Object -Unique)) { $t = Test-PsmServer $h; Line $t.Ok $h $t.Msg }
  Write-Host 'CCP authentication'
  try { $ca = Get-CcpAuth $E.Settings; Line $true "methods sent to CCP: $($ca.Desc)" } catch { Line $false 'CCP authentication settings' $_.Exception.Message }
  Write-Host 'PVWA / CCP (reachable, no logon)'
  foreach ($u in @($Rows | Where-Object { -not $_.Err } | ForEach-Object { $_.Env.PVWA; $_.Env.CCP_URL } | Sort-Object -Unique)) { $x = Http GET $u $null $null; Line ($x.Code -ne 0) $u $(if ($x.Code) { "http $($x.Code)" } else { "no answer: $($x.Content)" }) }
  if ($E.Mail -and $E.Mail.smtp_host) { Write-Host 'Mail'; $p = [int](Cfg $E.Mail 'smtp_port' 25); Line (Test-Tcp $E.Mail.smtp_host $p) "$($E.Mail.smtp_host):$p" ("to " + (@($E.Mail.to) -join ', ')) }
  $bad = $script:validateBad
  Write-Host ""; Write-Host $(if ($bad) { "$bad PROBLEM(S) FOUND" } else { 'ALL CHECKS PASSED' })
  $bad
}
# ------------------------------------------------------------------ high-level fixes, HTTP, report (shared with the first version)
# ------------------------------------------------------------------ high-level fixes per failed step (text only)
function Get-Fixes([string]$step, [string]$why) {
  $h = switch ($step) {
    'ccp' { 'Check the CCP service/URL is reachable from this host and returns HTTP 200.', "Check the AppID in PVWA > Applications: Allowed Machine includes this host's IP and the AppID is authorised on the end user's safe.", 'Check the safe, object name, and that the AppID/Provider has "Retrieve accounts" on that safe.' }
    'logon' { 'Check PVWA is up (HTTP 503 = application pool stopped).', "Check the password in the CCP object matches the end user's real password.", 'Check the end user is not suspended/expired/locked and the authentication method is allowed.', 'Check PVWA parameter AllowAPIAccess permits this user (CAWS00001E = API access blocked).' }
    'account' { 'Check the target account still exists in the target safe (not deleted, renamed or moved).', 'Check the end user has "List accounts" and "Use accounts" on the target safe.' }
    'connect' { 'Check the connection component exists, is enabled and assigned to the account platform.', 'Check the end user has "Use accounts" on the safe.', 'Check the PSM server is registered and healthy (PVWA > System Health).', 'Check the PVWA log for the PSMConnect error code.' }
    'session' { 'Check the PSM server is reachable on TCP 3389 and the CyberArk PSM service is running.', 'Check the newest *.RDP.log on the PSM server (...\PSM\Logs\Components).', 'Check the target is reachable from the PSM server and the target account may log on.', 'Check for a stale disconnected session of the target account on the target.' }
    'recording' {
      if ($why -match 'still live') { 'Session did not close after disconnect: check the disconnected-session timeout; terminate it from PVWA > Monitoring.' }
      elseif ($why -match 'shorter') { 'Session ended early: check target logon, RDP time limits and the PSM log for the session.' }
      elseif ($why -match 'error window') { 'A dialog or dispatcher error appeared inside the session (e.g. an unanswered host-key prompt or failed PSM-to-target connection).', 'Check the recording video, the host-key/prompt settings of the connection component, target reachability and the target account password.', 'If a prompt must be answered, use prompt_defaults in psm-test.json.' }
      else { 'No recording found: check the PSM recorder/service, disk space on the PSM server and Vault connectivity.', 'Check the PSMRecordings safe permissions for the PSM server user and that the end user can read the recordings safe.' }
    }
    default { 'No specific hint. Check the detail log and the PVWA/PSM logs.' }
  }
  ($h -join ' | ')
}

# ------------------------------------------------------------------ HTTP helper (never throws on HTTP errors)
function Http([string]$Method, [string]$Url, $Headers, $Body, $Extra = $null) {
  $p = @{ Uri = $Url; Method = $Method; UseBasicParsing = $true; TimeoutSec = 40; Headers = $(if ($Headers) { $Headers } else { @{} }) }
  if ($Extra) { foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] } }      # e.g. -Certificate / -UseDefaultCredentials for the CCP call only
  if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
  $sw_ = [Diagnostics.Stopwatch]::StartNew(); $xa_ = $(if ($Extra -and $Extra.Count -gt 0) { ' [extra auth: ' + (($Extra.Keys | Sort-Object) -join ', ') + ']' } else { '' })
  try { $x = Invoke-WebRequest @p; $c = $x.Content; if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }; Write-Trace "HTTP $Method $Url -> $([int]$x.StatusCode) in $($sw_.ElapsedMilliseconds) ms$xa_"; return @{ Code = [int]$x.StatusCode; Content = $c } }
  catch {
    $txt = ''; $code = 0
    if ($_.Exception.Response) {
      $code = [int]$_.Exception.Response.StatusCode
      try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $txt = $sr.ReadToEnd() } catch { }
      if (-not $txt -and $_.ErrorDetails) { $txt = $_.ErrorDetails.Message }
    } else { $txt = $_.Exception.Message }
    Write-Trace "HTTP $Method $Url -> $code in $($sw_.ElapsedMilliseconds) ms$xa_$(if ($code -eq 0) { ' (no answer: ' + $txt.Substring(0, [math]::Min(150, $txt.Length)) + ')' })"
    return @{ Code = $code; Content = $txt }
  }
}
# ------------------------------------------------------------------ how to authenticate TO CCP (env.json credentials.ccp; never from the CSV; only used for the CCP call)
#   AppID "Allowed machine" needs nothing here. "Certificate serial number" -> client_certificate_thumbprint. "OS user" -> windows_integrated (sends the Windows identity running the script).
function Find-CcpCertificate([string]$Thumbprint) {
  $t = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpper()
  if ($t.Length -lt 40) { throw "credentials.ccp.client_certificate_thumbprint is not a valid thumbprint (40 or more hex characters)" }
  $c = @(Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $t }) | Select-Object -First 1
  if (-not $c) { throw "CCP client certificate $t not found in the certificate store of the account running the script (CurrentUser\My or LocalMachine\My)" }
  if (-not $c.HasPrivateKey) { throw "CCP client certificate $t has no private key available to this account" }
  if ($c.NotAfter -lt (Get-Date)) { throw "CCP client certificate $t expired on $($c.NotAfter.ToString('yyyy-MM-dd'))" }
  $c
}
function Get-CcpAuth($Settings) {
  $thumb = [string](Cfg $Settings 'credentials.ccp.client_certificate_thumbprint' ''); $win = [bool](Cfg $Settings 'credentials.ccp.windows_integrated' $false)
  $params = @{}; $desc = @('allowed machine (IP)')
  if ($thumb) { $params.Certificate = Find-CcpCertificate $thumb; $desc += 'client certificate' }
  if ($win) { $params.UseDefaultCredentials = $true; $desc += "Windows account $env:USERDOMAIN\$env:USERNAME" }
  @{ Params = $params; Desc = ($desc -join ' + ') }
}
function ErrCode($content) { try { ($content | ConvertFrom-Json).ErrorCode } catch { '' } }
function Q([string]$s) { [uri]::EscapeDataString($s) }

# ------------------------------------------------------------------ report (HTML + text)
function E($s) { [Net.WebUtility]::HtmlEncode([string]$s) }
function Build-Report($table, [string]$runId, [string]$when, [int]$secs, [string]$csvPath, $kinds, [string]$note) {
  $nfail = @($table | Where-Object { $_.Result -ne 'PASS' }).Count; $nok = $table.Count - $nfail
  $head = if ($nfail) { "$nfail FAILED, $nok OK" } else { "All $nok tests OK" }
  $T = New-Object Collections.Generic.List[string]
  $T.Add("PSM HEALTH TEST - $head"); $T.Add("Run $runId | $when | host $HostName | ${secs}s | script SHA256 $ScriptHash"); $T.Add('')
  if ($note) { $T.Add($note); $T.Add('') }
  $T.Add(('{0,-3}{1,-20}{2,-12}{3,-15}{4,-14}{5,-7}{6,-11}{7}' -f '#', 'PSM server', 'Component', 'Target account', 'Target server', 'Result', 'Recording', 'Failed step'))
  foreach ($r in $table) {
    $rec = if ($r.RecordingId) { "$($r.RecordingSec)s" } else { '-' }
    $T.Add(('{0,-3}{1,-20}{2,-12}{3,-15}{4,-14}{5,-7}{6,-11}{7}' -f $r.Row, $r.TargetPSMServer, $r.'Connection-Component', $r.TargetAccount, $r.TargetServer, $r.Result, $rec, $r.FailedStep))
  }
  $H = New-Object Text.StringBuilder
  $col = if ($nfail) { '#b3261e' } else { '#2e7d32' }
  [void]$H.Append("<html><body style=`"font-family:Segoe UI,Arial,sans-serif;font-size:13px;color:#222`"><div style=`"padding:10px 14px;color:#fff;background:$col;font-size:16px`"><b>PSM health test - $(E $head)</b></div>")
  [void]$H.Append("<p style=`"color:#555`">Run <b>$(E $runId)</b> &middot; $(E $when) &middot; host $(E $HostName) &middot; ${secs}s$(if($note){"<br><i>$(E $note)</i>"})<br>Script SHA256 <code>$ScriptHash</code></p>")
  [void]$H.Append('<table cellpadding="5" style="border-collapse:collapse;border:1px solid #ccc"><tr style="background:#eee"><th>#</th><th>PSM server</th><th>Component</th><th>Target account</th><th>Target server</th><th>Result</th>')
  foreach ($k in $StepNames) { [void]$H.Append("<th>$($StepLabel[$k])</th>") }
  [void]$H.Append('<th>Recording</th><th>Time</th></tr>')
  foreach ($r in $table) {
    $ok = $r.Result -eq 'PASS'; $cells = ''
    foreach ($k in $StepNames) {
      $v = $r.$k
      if ($v -eq 'OK') { $cells += '<td align="center" style="color:#2e7d32;font-weight:bold">&#10003;</td>' }
      elseif ($v -eq 'FAIL') { $cells += '<td align="center" style="color:#b3261e;font-weight:bold">&#10007;</td>' }
      else { $cells += '<td align="center" style="color:#999;font-weight:bold">&ndash;</td>' }
    }
    $rec = if ($r.RecordingId) { "$(E $r.RecordingId) ($($r.RecordingSec)s)" } else { '&ndash;' }
    $bg = if ($ok) { '#2e7d32' } else { '#b3261e' }
    [void]$H.Append("<tr style=`"border-top:1px solid #ddd`"><td>$($r.Row)</td><td>$(E $r.TargetPSMServer)</td><td>$(E $r.'Connection-Component')</td><td>$(E $r.TargetAccount)@$(E $r.TargetAccountAddress)</td><td>$(E $r.TargetServer)</td><td style=`"color:#fff;background:$bg`" align=`"center`"><b>$($r.Result)</b></td>$cells<td>$rec</td><td>$($r.Seconds)s</td></tr>")
  }
  [void]$H.Append('</table>')
  $fails = @($table | Where-Object { $_.Result -ne 'PASS' })
  if ($fails) {
    $T.Add(''); $T.Add('FAILURES - what failed and what to try'); $T.Add('=' * 40)
    [void]$H.Append('<h3 style="color:#b3261e">Failures: what failed and what to try</h3>')
    foreach ($r in $fails) {
      $kind = if ($kinds -and $kinds["$($r.Row)"]) { $kinds["$($r.Row)"] } else { 'FAILED' }
      $steps = ($StepNames | ForEach-Object { "$($StepLabel[$_])=$($r.$_)" }) -join ', '
      $fx = @($r.Fixes -split ' \| ' | Where-Object { $_.Trim() })
      $T.Add(''); $T.Add("Row $($r.Row) [$kind]: $($r.TargetPSMServer) / $($r.'Connection-Component') / $($r.TargetAccount)@$($r.TargetAccountAddress) (end user $($r.PSMEnduser))")
      $T.Add("  Failed step: $($r.FailedStep)"); $T.Add("  Reason:      $($r.Reason)"); $T.Add("  Steps:       $steps"); $T.Add('  High-level fixes:')
      foreach ($x in $fx) { $T.Add("    - $x") }
      $T.Add("  Detail log on ${HostName}: $($r.DetailLog)")
      $li = ($fx | ForEach-Object { "<li>$(E $_)</li>" }) -join ''
      [void]$H.Append("<div style=`"border-left:4px solid #b3261e;padding:4px 12px;margin:10px 0;background:#fdf3f2`"><b>Row $($r.Row) &middot; $(E $kind)</b>: $(E $r.TargetPSMServer) / $(E $r.'Connection-Component') / $(E $r.TargetAccount)@$(E $r.TargetAccountAddress)<br><b>Failed step:</b> $(E $r.FailedStep)<br><b>Reason:</b> $(E $r.Reason)<br><b>Steps:</b> $(E $steps)<br><b>High-level fixes to try:</b><ul style=`"margin:4px 0`">$li</ul><span style=`"color:#666`">Detail log on $(E $HostName): $(E $r.DetailLog)</span></div>")
    }
  }
  # screenshots: the last picture of each session, embedded in the HTML (size-capped); the text part lists the files
  $images = @(); $usedKb = 0; $cap = [int]$script:ShotMailKb; $skipped = 0; $shotRows = @($table | Where-Object { $_.PSObject.Properties['Screenshot'] -and $_.Screenshot -and (Test-Path -LiteralPath $_.Screenshot) })
  if ($shotRows.Count) {
    [void]$H.Append('<h3>Screenshots of the sessions (the last picture taken while the session was open)</h3>'); $T.Add(''); $T.Add('SCREENSHOTS (last picture while the session was open)')
    foreach ($r in $shotRows) {
      $kb = [math]::Ceiling((Get-Item -LiteralPath $r.Screenshot).Length / 1KB); $T.Add("  row $($r.Row) $($r.'Connection-Component'): $($r.Screenshot)")
      if ($cap -gt 0 -and ($usedKb + $kb) -gt $cap) { $skipped++; continue }
      $usedKb += $kb; $cid = "shot$($r.Row)"; $images += @{ Cid = $cid; Path = $r.Screenshot }
      $col2 = if ($r.Result -eq 'PASS') { '#2e7d32' } else { '#b3261e' }
      [void]$H.Append("<p><b>Row $($r.Row) &middot; $(E $r.'Connection-Component') &middot; $(E $r.TargetAccount)</b> <span style=`"color:$col2`">$($r.Result)</span><br><img src=`"cid:$cid`" style=`"max-width:100%;border:1px solid #ccc`"></p>")
    }
    if ($skipped) { [void]$H.Append("<p style=`"color:#b3261e`">$skipped screenshot(s) not embedded (mail size limit $cap KB); the files are on $(E $script:HostName).</p>"); $T.Add("  $skipped screenshot(s) not embedded (mail size limit $cap KB)") }
  }
  $T.Add(''); $T.Add('WHAT EACH STEP MEANS')
  $T.Add('  CCP password = end user password fetched from CCP | REST logon = PVWA API logon | Target account = account found in its safe')
  $T.Add('  PSMConnect = PVWA created the PSM session | RDP session = connected to PSM and held for the hold time | Recording = closed recording in the Vault, long enough')
  $T.Add("Results CSV attached: $(Split-Path -Leaf $csvPath)")
  [void]$H.Append("<p style=`"color:#555;font-size:12px`"><b>Steps:</b> CCP password = end user password fetched from CCP &middot; REST logon = PVWA API logon &middot; Target account = account found in its safe &middot; PSMConnect = PVWA created the PSM session &middot; RDP session = connected to PSM and held &middot; Recording = closed recording in the Vault, long enough.<br>Results CSV attached: $(E (Split-Path -Leaf $csvPath))</p></body></html>")
  @{ Text = ($T -join "`n"); Html = $H.ToString(); Images = $images }
}

function New-ReportMessage([string]$subject, [string]$text, [string]$html, [string]$attach, $images = @()) {
  $m = New-Object Net.Mail.MailMessage; $m.From = $script:MailCfg.from; foreach ($t in @($script:MailCfg.to)) { $m.To.Add($t) }
  $m.Subject = $subject; $m.SubjectEncoding = [Text.Encoding]::UTF8; $m.BodyEncoding = [Text.Encoding]::UTF8
  $m.AlternateViews.Add([Net.Mail.AlternateView]::CreateAlternateViewFromString($text, [Text.Encoding]::UTF8, 'text/plain'))
  $hv = [Net.Mail.AlternateView]::CreateAlternateViewFromString($html, [Text.Encoding]::UTF8, 'text/html')
  foreach ($im in @($images)) { if ($im -and (Test-Path -LiteralPath $im.Path)) { $lr = New-Object Net.Mail.LinkedResource($im.Path, 'image/jpeg'); $lr.ContentId = $im.Cid; $hv.LinkedResources.Add($lr) } }
  $m.AlternateViews.Add($hv)
  if ($attach) { $m.Attachments.Add((New-Object Net.Mail.Attachment($attach))) }
  $m
}
function Send-Report([string]$subject, [string]$text, [string]$html, [string]$attach, $images = @()) {
  # recipients come from env.json only (read, never executed); anonymous SMTP, no stored credentials
  if ($script:MailCfg.dry_run) { Write-Host '--- MAIL DRY RUN (not sent) ---'; Write-Host "To: $(@($script:MailCfg.to) -join ', ')`nSubject: $subject`n"; Write-Host $text; return $true }
  $m = New-ReportMessage $subject $text $html $attach $images
  $c = New-Object Net.Mail.SmtpClient($script:MailCfg.smtp_host, [int](Cfg $script:MailCfg 'smtp_port' 25)); $c.Timeout = 20000
  try { $c.Send($m) } finally { $m.Dispose() }
  $true
}


# ------------------------------------------------------------------ one row: pre-check, retries
$script:ExtraFix = @{
  input = 'Fix the CSV row named in the reason (allowed characters: letters, digits and . _ : @ / - space; auth method LDAP/Cyberark/RADIUS/Windows; component must be in allowed_components in env.json).'
  runner = 'The test engine stopped unexpectedly: run with -Only <row> and read the output.'
  precheck = 'The PSM server is not reachable from this host: check DNS for the name, the PSM server/host firewall (TCP 3389) and that the PSM service is running.' }
function New-FailResult([string]$Step, [string]$Why) {
  [pscustomobject]@{ Result = 'FAIL'; FailedStep = $Step; Reason = $Why; Steps = @{}; PSMReturned = ''; Screenshot = ''; RecordingId = ''; RecordingSec = 0; DetailLog = ''; Fixes = $script:ExtraFix[$Step] }
}
function Invoke-Row($Row, $E, [string]$OutDir) {
  $t0 = Get-Date; $attempts = 0; $S = $Row.Env
  $script:TraceFile = $null
  if ($script:TraceOn) { $script:TraceFile = Join-Path $OutDir "row-$($Row.N).trace.log"; Write-Trace "psm-test $script:ToolVersion row $($Row.N): component $($S.COMPONENT), account $($S.ACCT_USER), PSM server '$($S.PSM_HOST)', end user $($S.PSM_USER), auth $($S.AUTH_METHOD)" }
  if ($Row.Err) { $res = New-FailResult 'input' $Row.Err }
  else {
    $pre = @{ Ok = $true; Msg = '' }
    if ($S.PSM_HOST -and [bool](Cfg $E.Settings 'prechecks.enabled' $true)) { $pre = Test-PsmServer $S.PSM_HOST ([int](Cfg $E.Settings 'prechecks.tcp_port' 3389)) }
    Write-Trace "precheck: $(if ($S.PSM_HOST) { if ($pre.Ok) { 'ok - ' + $pre.Msg } else { 'FAILED - ' + $pre.Msg } } else { 'skipped (no TargetPSMServer)' })"
    if (-not $pre.Ok) { $res = New-FailResult 'precheck' ('precheck: ' + $pre.Msg) }
    else {
      $maxTry = 1 + $(if ($null -ne $Row.Retries) { $Row.Retries } else { [int](Cfg $E.Settings 'reliability.retries' 1) })
      $wait = [int](Cfg $E.Settings 'reliability.retry_wait_sec' 60)
      for ($attempts = 1; $attempts -le $maxTry; $attempts++) {
        Write-Trace "--- attempt $attempts of $maxTry ---"
        $out = Join-Path $OutDir ("row-$($Row.N)" + $(if ($attempts -gt 1) { "-try$attempts" } else { '' }) + '.out')
        try { $res = Invoke-Test $S $out } catch { $res = New-FailResult 'runner' "test engine error: $($_.Exception.Message)" }
        if ($res.Result -eq 'PASS' -or $attempts -eq $maxTry) { break }
        Write-Host "           attempt $attempts failed at $($res.FailedStep) - retrying in ${wait}s"; if ($wait -gt 0) { Start-Sleep -Seconds $wait }
      }
      if ($attempts -gt $maxTry) { $attempts = $maxTry }
    }
  }
  if ($res.Screenshot -and $res.Result -eq 'PASS' -and $script:ShotMode -eq 'failures') { Remove-Item -LiteralPath $res.Screenshot -Force -ErrorAction SilentlyContinue; $res.Screenshot = '' }
  Write-Trace "row finished: $($res.Result)$(if ($res.Result -ne 'PASS') { ' at step ' + $res.FailedStep + ': ' + $res.Reason }) in $([int]((Get-Date) - $t0).TotalSeconds) s"
  $script:TraceFile = $null
  $res | Add-Member -NotePropertyName Secs -NotePropertyValue ([int]((Get-Date) - $t0).TotalSeconds) -Force
  $res | Add-Member -NotePropertyName Attempts -NotePropertyValue ([math]::Max($attempts, 1)) -Force
  $res
}

# ------------------------------------------------------------------ a full run
function Invoke-Run($E, $Rows, [bool]$NoMail) {
  $Mail = $E.Mail; $S_ = $E.Settings
  if (Test-Paused $E.Base) { Write-Host "environment '$($E.Name)' is PAUSED (remove with -Resume) - not starting"; return 4 }
  $lockPath = Join-Path $E.Base 'run.lock'
  $lk = Acquire-Lock $lockPath ([int](Cfg $S_ 'reliability.max_run_minutes' 60))
  if (-not $lk.Ok) { Write-Host "$($lk.Msg) - not starting"; return 3 }
  try {
    $runId = Get-Date -Format 'yyyyMMdd-HHmmss'; $outDir = Join-Path (Join-Path $E.Logs 'runs') $runId; New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $started = Get-Date; $results = @()
    foreach ($r in $Rows) {
      if (-not $r.Enabled) { Write-Host ("[{0:HH:mm:ss}] row {1}: disabled - skipped" -f (Get-Date), $r.N); continue }
      Write-Host ("[{0:HH:mm:ss}] row {1}: {2} {3} {4} ..." -f (Get-Date), $r.N, $r.Env.PSM_HOST, $r.Env.COMPONENT, $r.Env.ACCT_USER)
      $res = Invoke-Row $r $E $outDir; $results += [pscustomobject]@{ Row = $r; Res = $res }
      Write-Host ("           -> {0}{1} ({2}s{3})" -f $res.Result, $(if ($res.Result -ne 'PASS') { " at step $($res.FailedStep)" } else { '' }), $res.Secs, $(if ($res.Attempts -gt 1) { ", $($res.Attempts) attempts" } else { '' }))
    }
    # results CSV + JSON (standard columns always present)
    $csvPath = Join-Path $E.Results "psm-results-$runId.csv"
    $out = foreach ($x in $results) {
      $o = Get-Effective $x.Row
      $o.RunId = $runId; $o.Row = $x.Row.N; $o.Result = $x.Res.Result; $o.FailedStep = $x.Res.FailedStep; $o.Reason = $x.Res.Reason
      foreach ($s in $script:StepNames) { $o[$s] = $(if ($x.Res.Steps.ContainsKey($s)) { $x.Res.Steps[$s] } else { 'not run' }) }
      $o.PSMReturned = $x.Res.PSMReturned; $o.AccountID = $x.Res.AccountId; $o.Screenshot = $x.Res.Screenshot; $o.RecordingId = $x.Res.RecordingId; $o.RecordingSec = $x.Res.RecordingSec; $o.Seconds = $x.Res.Secs; $o.Attempts = $x.Res.Attempts
      $o.DetailLog = $x.Res.DetailLog; $o.Fixes = $x.Res.Fixes
      [pscustomobject]$o
    }
    $out | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $nfail = @($results | Where-Object { $_.Res.Result -ne 'PASS' }).Count; $npass = $results.Count - $nfail
    $jrows = @($results | ForEach-Object { @{ Row = $_.Row.N; Component = $_.Row.Env.COMPONENT; PSMServer = $_.Row.Env.PSM_HOST; Account = $_.Row.Env.ACCT_USER; Result = $_.Res.Result; FailedStep = $_.Res.FailedStep
                                              Reason = $_.Res.Reason; Seconds = $_.Res.Secs; RecordingSec = $_.Res.RecordingSec; RecordingId = $_.Res.RecordingId; Attempts = $_.Res.Attempts } })
    $summary = [ordered]@{ schema_version = 2; tool_version = $script:ToolVersion; environment = $E.Name; run_id = $runId; host = $script:HostName; time = (Get-Epoch); pass = $npass; fail = $nfail
                           seconds = [int]((Get-Date) - $started).TotalSeconds; tests = $jrows }
    if ([bool](Cfg $S_ 'outputs.json' $true)) { try { Write-JsonFile (Join-Path $E.Results "psm-results-$runId.json") $summary } catch { Write-Host "WARNING: results JSON could not be written: $($_.Exception.Message)" } }
    if ([bool](Cfg $S_ 'outputs.history' $true) -and $jrows.Count) { Add-History (Join-Path $E.Base 'history.csv') $runId $jrows }
    try { Write-JsonFile (Join-Path $E.Base 'status.json') ([ordered]@{ tool_version = $script:ToolVersion; environment = $E.Name; run_id = $runId; host = $script:HostName; time = (Get-Epoch); pass = $npass; fail = $nfail; seconds = $summary.seconds }) } catch { Write-Host "WARNING: status.json could not be written: $($_.Exception.Message)" }
    if ([bool](Cfg $S_ 'outputs.eventlog' $false)) { Write-EventLogEntry "run $runId env=$($E.Name) pass=$npass fail=$nfail" }
    $wh = [string](Cfg $S_ 'outputs.webhook_url' ''); if ($wh) { Write-Host "webhook: $(Send-Webhook $wh @{ environment = $E.Name; run_id = $runId; host = $script:HostName; time = (Get-Epoch); pass = $npass; fail = $nfail })" }
    $rot = Remove-OldFiles (Get-CleanupDirs $E) $script:KeepDays $script:ShotKeepDays
    Write-Host "`nRESULTS: $npass PASS, $nfail FAIL  ->  $csvPath$(if ($rot) { "   (removed $rot old files)" })"
    $code = $(if ($nfail) { 1 } else { 0 })
    # one summary mail per run, per-test policy: FAILED (after alert_after_failures) / STILL FAILING / RECOVERED
    if ($NoMail -or -not $Mail -or -not $Mail.smtp_host -or -not $Mail.to) { Write-Host 'mail: not sent'; return $code }
    $spath = Join-Path $E.Logs 'mail-state.json'; $state = Get-State $spath; $now = Get-Epoch
    $repeat = [int](Cfg $Mail 'repeat_hours' 6) * 3600; $after = [int](Cfg $S_ 'reliability.alert_after_failures' 1)
    $kinds = @{}; $plan = @()
    foreach ($x in $results) {
      $ev = Get-Effective $x.Row; $key = (@($ev['TargetPSMServer'], $ev['Connection-Component'], $ev['TargetAccount'], $ev['TargetAccountAddress']) -join '|'); if ($ev['TargetAccountID']) { $key += '|' + $ev['TargetAccountID'] }
      $d = Decide-Alert $state[$key] ($x.Res.Result -eq 'PASS') $now $repeat $after
      $kinds["$($x.Row.N)"] = $d.Kind; $plan += @{ Key = $key; Kind = $d.Kind; State = $d.State }
    }
    $always = (Cfg $Mail 'send_on' 'failure') -eq 'always'
    $sent = $false
    if (($kinds.Values | Where-Object { $_ }) -or $always) {
      $heads = @($kinds.Values | Where-Object { $_ } | Sort-Object -Unique)
      $subj = if ($nfail -eq 0) { "$script:Prefix ALL OK ($npass tests$(if ($heads) { ', ' + ($heads -join ', ') })) - run $runId" } else { "$script:Prefix $nfail FAILED, $npass OK$(if ($heads) { " ($($heads -join ', '))" }) - run $runId" }
      $tbl = @(Import-Csv -LiteralPath $csvPath)
      $rep = Build-Report $tbl $runId (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ([int]((Get-Date) - $started).TotalSeconds) $csvPath $kinds "psm-test $script:ToolVersion / environment $($E.Name)$(if ($script:ManualCred) { " / credentials: MANUAL user $($script:ManualCred.UserName)" })$(if ($script:TraceOn) { " / TRACE ON: files in logs\runs\$runId" })"
      try { $sent = [bool](Send-Report $subj $rep.Text $rep.Html $csvPath $rep.Images) } catch { Write-Host "WARNING: mail could not be sent: $($_.Exception.Message)" }
    }
    foreach ($p in $plan) { if ($sent) { Mark-Sent $p.State $p.Kind $now }; $state[$p.Key] = $p.State }
    if (-not $Mail.dry_run) { Write-JsonFile $spath $state }
    Write-Host ("mail: " + $(if ($sent -and -not $Mail.dry_run) { 'sent' } elseif ($sent) { 'dry run printed' } else { 'nothing to report' }))
    return $code
  } finally { if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } }
}

# ------------------------------------------------------------------ heartbeat, test mail, resend
function Invoke-Heartbeat($E, [bool]$NoMail) {
  $hours = [double](Cfg $E.Settings 'reliability.heartbeat_hours' 0)
  if (-not $hours) { Write-Host 'heartbeat: not configured (reliability.heartbeat_hours)'; return 0 }
  $st = Read-Json (Join-Path $E.Base 'status.json'); $age = if ($st) { ((Get-Epoch) - [long]$st.time) / 3600 } else { 1e9 }
  if ($age -le $hours) { Write-Host ("heartbeat OK: last run {0:N1}h ago (limit {1}h)" -f $age, $hours); return 0 }
  $msg = "No PSM health test run has finished for $([math]::Round($age,1))h (limit ${hours}h) on $script:HostName. The schedule may have stopped, the host may be down, or the environment is paused ($(if (Test-Paused $E.Base) { 'yes' } else { 'no' }))."
  Write-Host "HEARTBEAT MISSED: $msg"
  $hb = Join-Path $E.Base 'heartbeat-alert.json'; $last = 0; $j = Read-Json $hb; if ($j) { $last = [long]$j.sent }
  if ($NoMail -or -not $E.Mail.smtp_host -or ((Get-Epoch) - $last) -lt 6 * 3600) { return 2 }
  try {
    if ($E.Mail.dry_run) { Write-Host "--- MAIL DRY RUN ---`n$msg" }
    else {
      $m = New-Object Net.Mail.MailMessage; $m.From = $E.Mail.from; foreach ($t in @($E.Mail.to)) { $m.To.Add($t) }; $m.Subject = "$script:Prefix HEARTBEAT MISSED - no test run for $([math]::Round($age))h"; $m.Body = $msg
      (New-Object Net.Mail.SmtpClient($E.Mail.smtp_host, [int](Cfg $E.Mail 'smtp_port' 25))).Send($m); Write-JsonFile $hb @{ sent = (Get-Epoch) }
    }
  } catch { Write-Host "heartbeat mail NOT sent: $($_.Exception.Message)" }
  2
}
function Send-TestMail($Mail) {
  $m = New-Object Net.Mail.MailMessage; $m.From = $Mail.from; foreach ($t in @($Mail.to)) { $m.To.Add($t) }
  $m.Subject = "$script:Prefix TEST MAIL - please ignore"
  $m.Body = "This is a TEST message from the PSM health test on $script:HostName at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').`nIf you can read this, mail delivery from the test host to this mailbox works. No action needed."
  try { (New-Object Net.Mail.SmtpClient($Mail.smtp_host, [int](Cfg $Mail 'smtp_port' 25))).Send($m); Write-Host "test mail sent to $(@($Mail.to) -join ', ')"; 0 }
  catch { $ie = $_.Exception; while ($ie.InnerException) { $ie = $ie.InnerException }; Write-Host "test mail NOT sent: $($_.Exception.Message) - cause: $($ie.Message) (SMTP $($Mail.smtp_host):$(Cfg $Mail 'smtp_port' 25))"; 1 }
}

# ------------------------------------------------------------------ command line
function Invoke-Cli([hashtable]$A) {
  if ($A.Version) { Write-Host "psm-test $script:ToolVersion"; return 0 }
  $name = Get-EnvName $A.Environment; $E = Load-Environment $name; Set-RunVars $E.Settings $E.Mail
  if ($env:PSMT_MAIL_DRYRUN -eq '1' -and $E.Mail) { $E.Mail | Add-Member -NotePropertyName dry_run -NotePropertyValue $true -Force }
  if ($A.Pause -or $A.Resume) { Set-Pause $E.Base ([bool]$A.Pause); Write-Host "environment $name $(if ($A.Pause) { 'PAUSED' } else { 'resumed' })"; return 0 }
  if ($A.TestMail) { return (Send-TestMail $E.Mail) }
  if ($A.HeartbeatCheck) { return (Invoke-Heartbeat $E ([bool]$A.NoMail)) }
  if ($A.CleanupPreview) { return (Show-CleanupPreview $E) }
  if ($A.Resend) {
    $table = @(Import-Csv -LiteralPath $A.Resend); $rid = $table[0].RunId; $nf = @($table | Where-Object { $_.Result -ne 'PASS' }).Count
    $rep = Build-Report $table $rid ((Get-Item $A.Resend).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) (($table | Measure-Object -Property Seconds -Sum).Sum) $A.Resend @{} 'Re-sent from an existing results file (test of the report format).'
    try { Send-Report "$script:Prefix $nf FAILED, $($table.Count - $nf) OK - run $rid (re-sent report)" $rep.Text $rep.Html $A.Resend $rep.Images | Out-Null; Write-Host 'report mail sent'; return 0 }
    catch { Write-Host "report mail NOT sent: $($_.Exception.Message)"; return 1 }
  }
  $csv = if ($A.Csv) { $A.Csv } else { $E.Tests }
  $rows = @(Read-Rows $csv $E.Settings)
  if ($A.Only) { $keep = $A.Only.Split(',') | ForEach-Object { [int]$_ }; $rows = @($rows | Where-Object { $keep -contains $_.N }) }
  if ($A.Validate) { return (Invoke-Validate $E $rows) }
  if ($A.DryRun) { foreach ($r in $rows) { Write-Host $r.N $(if ($r.Err) { $r.Err } else { 'ok' }) $(if (-not $r.Enabled) { '(disabled)' }) ($r.Env.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }); }; return 0 }
  if ($A.Screenshots) { $script:ShotMode = $A.Screenshots }
  $script:TraceOn = [bool]$A.Trace
  if ($script:TraceOn) { Write-Host 'trace: ON - detailed files logs\runs\<run id>\row-N.trace.log (no passwords, tokens or request bodies are ever written)' }
  $script:ManualCred = $null
  if ($A.Credential -or $A.Manual) {
    $cred = $A.Credential
    if (-not $cred) { $cred = Get-Credential -UserName ([string](Cfg $E.Settings 'enduser.name' '')) -Message 'PSM health test: manual credentials. Used for ALL rows of this run, kept only in memory, never saved.' }
    if (-not $cred -or -not $cred.UserName -or $cred.Password.Length -eq 0) { Write-Host 'no credentials entered - not starting'; return 5 }
    if ($cred.UserName -notmatch '^[A-Za-z0-9._:@/\-]{1,128}$') { Write-Host 'the user name has characters that are not allowed (letters, digits and . _ : @ / - only) - not starting'; return 5 }
    $script:ManualCred = $cred
    foreach ($r in $rows) { if (-not $r.Err) { $r.Env.PSM_USER = $cred.UserName } }
    Write-Host "credentials: MANUAL for user $($cred.UserName) (used for all rows; password not shown, not saved)"
  } else { Write-Host 'credentials: from CCP (per row)' }
  Invoke-Run $E $rows ([bool]$A.NoMail)
}
