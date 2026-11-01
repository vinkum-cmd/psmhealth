<#
 Offline self-test of the tool itself: runs the real run flow (lib\Core.ps1) with a MOCK session and a MOCK mail sender.
 Opens no PSM session, sends no mail, needs no network. Run:  powershell.exe -STA -File .\tests\Test-Selftest.ps1
#>
$ErrorActionPreference = 'Stop'
# this test points the tool at temporary folders through two environment variables; they are put back to what they were when the test ends (or crashes)
$script:OldHome = $env:PSMT_HOME; $script:OldEnv = $env:PSMT_ENV
function Restore-TestEnv { if ($null -eq $script:OldHome) { Remove-Item Env:PSMT_HOME -ErrorAction SilentlyContinue } else { $env:PSMT_HOME = $script:OldHome }; if ($null -eq $script:OldEnv) { Remove-Item Env:PSMT_ENV -ErrorAction SilentlyContinue } else { $env:PSMT_ENV = $script:OldEnv } }
trap { Restore-TestEnv; break }
$ToolRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ToolVersion = 'selftest'; $HostName = 'selftest-host'; $Hold = 0
. (Join-Path $ToolRoot 'lib\Core.ps1')       # NOT Engine.ps1 - the session function is replaced by a mock below

$script:Seq = New-Object Collections.Generic.List[string]; $script:Calls = 0; $script:Mails = @(); $script:UserSeen = @()
function Invoke-Test([hashtable]$S, [string]$OutFile) {   # mock session: pops "PASS" or "FAIL:<step>:<reason>"
  $script:Calls++; $script:UserSeen += $S.PSM_USER; $line = if ($script:Seq.Count) { $script:Seq[0] } else { 'PASS' }; if ($script:Seq.Count) { $script:Seq.RemoveAt(0) }
  'mock' | Set-Content -LiteralPath $OutFile
  $sp = ''; if ($script:ShotMode -ne 'off') { $sp = [IO.Path]::ChangeExtension($OutFile, 'screen.jpg'); [IO.File]::WriteAllBytes($sp, [byte[]](1..200)) }
  if ($line -eq 'PASS') { return [pscustomobject]@{ Result = 'PASS'; FailedStep = ''; Reason = ''; Steps = @{ ccp = 'OK'; logon = 'OK'; account = 'OK'; connect = 'OK'; session = 'OK'; recording = 'OK' }; PSMReturned = ''; RecordingId = '40_1'; RecordingSec = 50; DetailLog = ''; Fixes = ''; Screenshot = $sp } }
  $p = $line.Split(':', 3)
  [pscustomobject]@{ Result = 'FAIL'; FailedStep = $p[1]; Reason = "$($p[1]): $($p[2])"; Steps = @{ ccp = 'OK'; session = 'FAIL' }; PSMReturned = ''; RecordingId = ''; RecordingSec = 0; DetailLog = ''; Fixes = 'mock fix'; Screenshot = $sp }
}
function Send-Report($subject, $text, $html, $attach, $images) { $script:Mails += "$subject`n$text"; $true }   # mock mail

$script:Fail = 0; $script:Pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:Pass++; Write-Host "  [ok]   $what" } else { $script:Fail++; Write-Host "  [FAIL] $what" } }
function New-Home($Env, $CsvText) {
  $h = Join-Path ([IO.Path]::GetTempPath()) ("psmt-" + [guid]::NewGuid().ToString('N').Substring(0, 8)); $b = Join-Path $h 'envs\t'; New-Item -ItemType Directory -Force -Path $b | Out-Null
  $Env | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $b 'env.json'); $CsvText | Set-Content -LiteralPath (Join-Path $b 'tests.csv'); $env:PSMT_HOME = $h; $env:PSMT_ENV = 't'
  $h
}
function Base-Env { @{ schema = 2; pvwa_url = 'https://pvwa.test'; enduser = @{ name = 'u1'; auth_method = 'LDAP'; ccp = @{ app_id = 'A'; safe = 'S'; object = 'O' } }; target = @{ account_safe = 'TS' }
  allowed_components = @('PSM-RDP', 'PSM-SSH'); test = @{}; reliability = @{ retries = 1; retry_wait_sec = 0; alert_after_failures = 1; max_run_minutes = 60; heartbeat_hours = 1 }
  prechecks = @{ enabled = $false }; outputs = @{ keep_days = 30 }; mail = @{ smtp_host = 'stub'; smtp_port = 25; from = 'a@t'; to = @('b@t'); repeat_hours = 6; subject_prefix = '[T]' } } }
$Csv1 = "Connection-Component,TargetAccount,TargetAccountAddress`nPSM-RDP,acc1,addr1"
function Go([string[]]$Seq, [hashtable]$Extra = @{}) {
  $script:Seq.Clear(); foreach ($s in $Seq) { $script:Seq.Add($s) }; $script:Calls = 0
  $a = @{ Environment = 't'; Csv = ''; Only = ''; NoMail = $false; DryRun = $false; Validate = $false; Pause = $false; Resume = $false; HeartbeatCheck = $false; TestMail = $false; Resend = ''; Version = $false; Manual = $false; Credential = $null; Trace = $false; Screenshots = ''; CleanupPreview = $false }
  foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
  $null = $true; $code = (Invoke-Cli $a 6>&1 | Where-Object { $_ -is [int] } | Select-Object -Last 1); $code
}
function Base([string]$h) { Join-Path $h 'envs\t' }

Write-Host '1 CSV defaults and columns'
$h = New-Home (Base-Env) $Csv1; $E = Load-Environment 't'; $rows = @(Read-Rows $E.Tests $E.Settings)
Check ($rows[0].Err -eq '') 'row valid'; Check ($rows[0].Env.PSM_USER -eq 'u1') 'end user from env.json'; Check ($rows[0].Env.ACCT_SAFE -eq 'TS') 'safe from env.json'; Check ($rows[0].Env.PVWA -eq 'https://pvwa.test') 'PVWA from env.json'

Write-Host '2 CSV rejections'
function Err1($cols, $vals) { $h = New-Home (Base-Env) "Connection-Component,TargetAccount$cols`nPSM-RDP,acc1$vals"; $E = Load-Environment 't'; (Read-Rows $E.Tests $E.Settings)[0].Err }
Check ((Err1 ',ExpectedTitle' ',bad;title') -match 'characters not allowed') 'bad character refused'
Check ((Err1 ',HoldSec' ',5') -match 'HoldSec') 'HoldSec < 10 refused'; Check ((Err1 ',Retries' ',9') -match 'Retries') 'Retries 9 refused'
Check ((Err1 ',Enabled' ',maybe') -match 'Enabled') 'Enabled maybe refused'; Check ((Err1 ',DismissPromptKey' ',Delete') -match 'DismissPromptKey') 'key Delete refused'
Check ((Err1 ',HoldSec,Retries,Enabled,DismissPromptKey' ',60,2,no,Y') -eq '') 'valid optional columns accepted'
$h = New-Home (Base-Env) "Connection-Component,TargetAccount,Surprise`nPSM-RDP,a,b"; $E = Load-Environment 't'; $threw = $false; try { Read-Rows $E.Tests $E.Settings | Out-Null } catch { $threw = $true }; Check $threw 'unknown column refused'
$h = New-Home (Base-Env) "Connection-Component,TargetAccount`nPSM-WEB,a"; $E = Load-Environment 't'; Check ((Read-Rows $E.Tests $E.Settings)[0].Err -match 'allowed_components') 'component not in allowed_components refused'

Write-Host '3 alert state machine'
$d = Decide-Alert $null $false 1000 21600 2; Check ($d.Kind -eq '') 'first failure held back (alert_after 2)'
$d = Decide-Alert $d.State $false 2000 21600 2; Check ($d.Kind -eq 'FAILED') 'second failure alerts'; Mark-Sent $d.State 'FAILED' 2000
$d2 = Decide-Alert $d.State $false 3000 21600 2; Check ($d2.Kind -eq '') 'no repeat inside repeat_hours'
$d3 = Decide-Alert $d.State $false (2000 + 25000) 21600 2; Check ($d3.Kind -eq 'STILL FAILING') 'repeat after repeat_hours'
$d4 = Decide-Alert $d.State $true 40000 21600 2; Check ($d4.Kind -eq 'RECOVERED') 'recovery after an alert'

Write-Host '4 run flow'
$h = New-Home (Base-Env) $Csv1; $b = Base $h; $script:Mails = @()
$c = Go @('PASS'); Check ($c -eq 0) 'pass exits 0'; Check ($script:Mails.Count -eq 0) 'pass sends no mail'
Check (Test-Path (Join-Path $b 'status.json')) 'status.json written'; Check (Test-Path (Join-Path $b 'history.csv')) 'history.csv written'
$j = Get-ChildItem (Join-Path $b 'results') -Filter *.json | Select-Object -First 1; $jo = Get-Content -Raw $j.FullName | ConvertFrom-Json; Check (($jo.schema_version -eq 2) -and ($jo.pass -eq 1)) 'results JSON'
$c = Go @('FAIL:session:boom', 'PASS'); Check (($c -eq 0) -and ($script:Calls -eq 2) -and ($script:Mails.Count -eq 0)) 'retry then pass: no alert'
$c = Go @('FAIL:session:boom', 'FAIL:session:boom'); Check (($c -eq 1) -and ($script:Mails.Count -eq 1) -and ($script:Mails[0] -match 'FAILED') -and ($script:Mails[0] -match 'boom')) 'two failures: one FAILED mail'
$c = Go @('FAIL:session:boom', 'FAIL:session:boom'); Check ($script:Mails.Count -eq 1) 'no repeat mail inside repeat_hours'
$c = Go @('PASS'); Check (($c -eq 0) -and ($script:Mails.Count -eq 2) -and ($script:Mails[1] -match 'RECOVERED')) 'recovery mail'
$c = Go @('PASS'); Check ($script:Mails.Count -eq 2) 'pass after recovery sends nothing'

Write-Host '5 alert_after_failures = 2'
$e = Base-Env; $e.reliability.alert_after_failures = 2; $e.reliability.retries = 0; $h = New-Home $e $Csv1; $script:Mails = @()
Go @('FAIL:session:x') | Out-Null; Check ($script:Mails.Count -eq 0) 'first failure held back'
Go @('FAIL:session:x') | Out-Null; Check ($script:Mails.Count -eq 1) 'second failure alerts'
$h = New-Home $e $Csv1; $script:Mails = @(); Go @('FAIL:session:x') | Out-Null; Go @('PASS') | Out-Null; Check ($script:Mails.Count -eq 0) 'a failure that never alerted recovers silently'

Write-Host '6 disabled rows, pre-check, lock, pause, heartbeat, cleanup'
$h = New-Home (Base-Env) "Connection-Component,TargetAccount,Enabled,Retries`nPSM-RDP,off,no,`nPSM-SSH,on,yes,0"; $script:Mails = @()
Go @('FAIL:session:x') -Extra @{ NoMail = $true } | Out-Null; Check ($script:Calls -eq 1) 'disabled row skipped; per-row Retries=0 honoured'
$e = Base-Env; $e.prechecks = @{ enabled = $true; tcp_port = 3389 }; $h = New-Home $e "Connection-Component,TargetAccount,TargetPSMServer`nPSM-RDP,acc,nonexistent.invalid"
$c = Go @('PASS') -Extra @{ NoMail = $true }; Check (($c -eq 1) -and ($script:Calls -eq 0)) 'unreachable PSM server fails fast, engine not called'
$h = New-Home (Base-Env) $Csv1; $b = Base $h; "other|1|$(Get-Epoch)" | Set-Content (Join-Path $b 'run.lock')
$c = Go @('PASS') -Extra @{ NoMail = $true }; Check (($c -eq 3) -and ($script:Calls -eq 0)) 'fresh lock blocks a second run'
"other|1|$((Get-Epoch) - 7200)" | Set-Content (Join-Path $b 'run.lock'); $c = Go @('PASS') -Extra @{ NoMail = $true }; Check (($c -eq 0) -and -not (Test-Path (Join-Path $b 'run.lock'))) 'stale lock replaced, lock released'
Go @() -Extra @{ Pause = $true } | Out-Null; $c = Go @('PASS') -Extra @{ NoMail = $true }; Check (($c -eq 4) -and ($script:Calls -eq 0)) 'paused: run refuses'
Go @() -Extra @{ Resume = $true } | Out-Null; $c = Go @('PASS') -Extra @{ NoMail = $true }; Check ($c -eq 0) 'resumed: run works'
$st = Get-Content -Raw (Join-Path $b 'status.json') | ConvertFrom-Json; $st.time = (Get-Epoch) - 3 * 3600; $st | ConvertTo-Json | Set-Content (Join-Path $b 'status.json')
$c = Go @() -Extra @{ HeartbeatCheck = $true; NoMail = $true }; Check ($c -eq 2) 'heartbeat: stale status detected'
$old = Join-Path $b 'results\psm-results-old.csv'; 'x' | Set-Content $old; (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-60)
Go @('PASS') -Extra @{ NoMail = $true } | Out-Null; Check (-not (Test-Path $old)) 'old result files removed'; Check (Test-Path (Join-Path $b 'history.csv')) 'history kept'

Write-Host '6b TCP probe against a real local listener'
$lis = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $lis.Start(); $port = ([Net.IPEndPoint]$lis.LocalEndpoint).Port
Check (Test-Tcp '127.0.0.1' $port 3000) 'open port detected'
$lis.Stop(); Check (-not (Test-Tcp '127.0.0.1' $port 1500)) 'closed port detected'
Check ((Test-PsmServer '127.0.0.1' 1).Ok -eq $false) 'Test-PsmServer reports an unreachable port'

Write-Host '6c manual credentials'
$h = New-Home (Base-Env) "Connection-Component,TargetAccount`nPSM-RDP,a`nPSM-SSH,b"; $script:Mails = @(); $script:UserSeen = @()
$cred = New-Object Management.Automation.PSCredential('manual.user', (ConvertTo-SecureString 'dummy-not-a-real-secret' -AsPlainText -Force))
Go @('FAIL:session:x', 'FAIL:session:x', 'FAIL:session:x', 'FAIL:session:x') -Extra @{ Credential = $cred } | Out-Null
Check ((@($script:UserSeen | Select-Object -Unique)).Count -eq 1 -and $script:UserSeen[0] -eq 'manual.user') 'the manual user replaces the CSV end user for every row'
Check (($script:Mails.Count -eq 1) -and ($script:Mails[0] -match 'credentials: MANUAL user manual.user')) 'the mail says the credentials were manual'
Check (-not ($script:Mails[0] -match 'dummy-not-a-real-secret')) 'the password is not in the mail'
$script:UserSeen = @(); Go @('PASS') -Extra @{ NoMail = $true } | Out-Null; Check ($script:UserSeen[0] -eq 'u1') 'without -Manual/-Credential the CCP end user is used again (nothing is remembered between runs)'
$badc = New-Object Management.Automation.PSCredential('bad;user', (ConvertTo-SecureString 'x' -AsPlainText -Force)); $script:Calls = 0
$c = Go @('PASS') -Extra @{ Credential = $badc; NoMail = $true }; Check (($c -eq 5) -and ($script:Calls -eq 0)) 'a user name with forbidden characters is refused'

Write-Host '6d success mail (send_on = always)'
$e = Base-Env; $e.mail.send_on = 'always'; $h = New-Home $e $Csv1; $script:Mails = @()
Go @('PASS') | Out-Null; Check (($script:Mails.Count -eq 1) -and ($script:Mails[0] -match 'ALL OK')) 'an all-pass run sends one "ALL OK" mail'
Go @('PASS') | Out-Null; Check ($script:Mails.Count -eq 2) 'and again on the next run'
$c = Go @('PASS') -Extra @{ NoMail = $true }; Check (($c -eq 0) -and ($script:Mails.Count -eq 2)) '-NoMail still suppresses it'

Write-Host '6e CCP authentication settings (env.json credentials.ccp)'
$a0 = Get-CcpAuth ([pscustomobject]@{}); Check (($a0.Params.Count -eq 0) -and ($a0.Desc -eq 'allowed machine (IP)')) 'blank settings: nothing extra is sent (IP only, as before)'
$a1 = Get-CcpAuth ('{"credentials":{"ccp":{"windows_integrated":true}}}' | ConvertFrom-Json); Check (($a1.Params.UseDefaultCredentials -eq $true) -and ($a1.Desc -match 'Windows account')) 'windows_integrated sends the Windows identity'
$m = ''; try { Get-CcpAuth ('{"credentials":{"ccp":{"client_certificate_thumbprint":"nothex"}}}' | ConvertFrom-Json) | Out-Null } catch { $m = $_.Exception.Message }; Check ($m -match 'not a valid thumbprint') 'a malformed thumbprint is refused'
$m = ''; try { Get-CcpAuth ('{"credentials":{"ccp":{"client_certificate_thumbprint":"0000000000000000000000000000000000000000"}}}' | ConvertFrom-Json) | Out-Null } catch { $m = $_.Exception.Message }; Check ($m -match 'not found') 'a certificate that is not in the store gives a clear message'
$cert = $null; try { $cert = New-SelfSignedCertificate -Subject 'CN=psm-selftest' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(1) -ErrorAction Stop } catch { }
if ($cert) {
  $a2 = Get-CcpAuth (('{"credentials":{"ccp":{"client_certificate_thumbprint":"' + $cert.Thumbprint + '","windows_integrated":true}}}') | ConvertFrom-Json)
  Check (($a2.Params.Certificate.Thumbprint -eq $cert.Thumbprint) -and ($a2.Params.UseDefaultCredentials -eq $true)) 'certificate and Windows account can be combined'
  Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $cert.Thumbprint) -Force
} else { Write-Host '  [skip] could not create a test certificate on this host' }

Write-Host '6f -Trace'
$tf = Join-Path ([IO.Path]::GetTempPath()) ('trace-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log'); $script:TraceOn = $true; $script:TraceFile = $tf
$null = Http POST 'http://127.0.0.1:1/x?y=1' @{ Authorization = 'tok-secret-123' } '{"password":"pw-secret-456"}'
$tt = Get-Content -Raw -LiteralPath $tf
Check ($tt -match 'HTTP POST http://127.0.0.1:1/x\?y=1 -> 0') 'a web call is traced (method, address, answer code)'
Check (($tt -notmatch 'tok-secret-123') -and ($tt -notmatch 'pw-secret-456')) 'the token and the request body never reach the trace'
$script:TraceOn = $false; $script:TraceFile = $null; Remove-Item -LiteralPath $tf -Force
$h = New-Home (Base-Env) $Csv1; Go @('PASS') -Extra @{ Trace = $true; NoMail = $true } | Out-Null
$tr = Get-ChildItem (Join-Path (Base $h) 'logs\runs') -Recurse -Filter 'row-1.trace.log' | Select-Object -First 1
Check ($null -ne $tr) 'with -Trace every row gets a trace file'
if ($tr) { $tc = Get-Content -Raw -LiteralPath $tr.FullName; Check (($tc -match '--- attempt 1 of') -and ($tc -match 'row finished: PASS')) 'it records the attempt and the outcome' }
$script:TraceOn = $false; $h = New-Home (Base-Env) $Csv1; Go @('PASS') -Extra @{ NoMail = $true } | Out-Null
Check (-not (Get-ChildItem (Join-Path (Base $h) 'logs\runs') -Recurse -Filter '*.trace.log')) 'without -Trace no trace file is written'

Write-Host '6g TargetAccountID'
$h = New-Home (Base-Env) "Connection-Component,TargetAccountID`nPSM-RDP,12_34"; $E = Load-Environment 't'; $r = (Read-Rows $E.Tests $E.Settings)[0]
Check ($r.Err -eq '') 'a row with only a TargetAccountID (no user name, no safe) is valid'
Check (($r.Env.ACCT_ID -eq '12_34') -and (-not $r.Env.ContainsKey('ACCT_SAFE'))) 'the default safe is not applied to an id row'
Check ((Err1 ',TargetAccountID' ',41-5') -match 'must look like') 'a malformed id is refused'
Check ((Err1 ',TargetAccountID' ',12_34') -eq '') 'an id together with a user name is accepted (the engine checks they match)'
$h = New-Home (Base-Env) "Connection-Component,TargetAccountID`nPSM-RDP,12_34`nPSM-RDP,12_35"; $script:Mails = @()
Go @('FAIL:session:x', 'FAIL:session:x', 'FAIL:session:x', 'FAIL:session:x') | Out-Null
$st = Get-Content -Raw -LiteralPath (Join-Path (Base $h) 'logs\mail-state.json') | ConvertFrom-Json
Check (@($st.PSObject.Properties).Count -eq 2) 'two id-only rows keep separate alert state'

Write-Host '6h reason with day and time'
$rs = Get-RunReason 'automated psm health test' ([datetime]'2026-10-31 16:06:06')
Check ($rs -ceq 'automated psm health test on Saturday 2026-10-31 16:06:06') 'reason = text + English day name + date + time'
Check ((Get-RunReason 'x') -match '^x on [A-Za-z]+ \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') 'the current time is used by default'

Write-Host '6i screenshots'
function ShotFiles($h) { @(Get-ChildItem (Join-Path (Base $h) 'logs\runs') -Recurse -Filter '*.screen.jpg' -ErrorAction SilentlyContinue) }
$e = Base-Env; $e.screenshots = @{ mode = 'failures' }; $h = New-Home $e $Csv1
Go @('PASS') -Extra @{ NoMail = $true } | Out-Null; Check ((ShotFiles $h).Count -eq 0) 'failures mode: the picture of a passed row is not kept'
Go @('FAIL:session:x', 'FAIL:session:x') -Extra @{ NoMail = $true } | Out-Null; Check ((ShotFiles $h).Count -ge 1) 'failures mode: the picture of a failed row is kept'
$e = Base-Env; $e.screenshots = @{ mode = 'all' }; $h = New-Home $e $Csv1
Go @('PASS') -Extra @{ NoMail = $true } | Out-Null
$rr = Import-Csv -LiteralPath (Get-ChildItem (Join-Path (Base $h) 'results') -Filter *.csv | Select-Object -First 1).FullName
Check ($rr.Screenshot -and (Test-Path -LiteralPath $rr.Screenshot)) 'all mode: the picture of a passed row is kept and listed in the results'
$e = Base-Env; $e.screenshots = @{ mode = 'all' }; $h = New-Home $e $Csv1
Go @('PASS') -Extra @{ NoMail = $true; Screenshots = 'off' } | Out-Null; Check ((ShotFiles $h).Count -eq 0) '-Screenshots off overrides env.json'
$jpg = Join-Path ([IO.Path]::GetTempPath()) ('shot-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.screen.jpg'); [IO.File]::WriteAllBytes($jpg, (New-Object byte[] 5120))
$tbl = @([pscustomobject]@{ Row = '1'; TargetPSMServer = 's'; 'Connection-Component' = 'PSM-RDP'; TargetAccount = 'a'; TargetAccountAddress = 'x'; TargetServer = 't'; Result = 'PASS'; RecordingId = '1_1'; RecordingSec = '5'; FailedStep = ''; Seconds = '5'
  PSMEnduser = 'u'; ccp = 'OK'; logon = 'OK'; account = 'OK'; connect = 'OK'; session = 'OK'; recording = 'OK'; Reason = ''; Fixes = ''; DetailLog = ''; Screenshot = $jpg })
$script:MailCfg = [pscustomobject]@{ from = 'a@t'; to = @('b@t') }; $script:ShotMailKb = 3000
$rep = Build-Report $tbl 'r1' 'now' 5 'x.csv' @{} ''; Check (($rep.Html -match 'cid:shot1') -and ($rep.Images.Count -eq 1)) 'the report embeds the picture'
$m = New-ReportMessage 's' $rep.Text $rep.Html $null $rep.Images; $nlr = 0; foreach ($av in $m.AlternateViews) { $nlr += $av.LinkedResources.Count }; $m.Dispose(); Check ($nlr -eq 1) 'the mail message carries the picture as an inline image'
$script:ShotMailKb = 1; $rep2 = Build-Report $tbl 'r1' 'now' 5 'x.csv' @{} ''; Check (($rep2.Images.Count -eq 0) -and ($rep2.Text -match 'not embedded')) 'a picture over the mail size limit is not embedded (and the report says so)'
Remove-Item -LiteralPath $jpg -Force

Write-Host '6j cleanup limits and preview'
$e = Base-Env; $e.outputs = @{ keep_days = 30; screenshot_keep_days = 7 }; $h = New-Home $e $Csv1; $b = Base $h
$rd = Join-Path $b 'logs\runs\19990101-000000'; New-Item -ItemType Directory -Force -Path $rd, (Join-Path $b 'results') | Out-Null
$mk = { param($path, $days) 'x' | Set-Content -LiteralPath $path; (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-$days) }
$shotOld = Join-Path $rd 'row-1.screen.jpg'; $logMid = Join-Path $rd 'row-1.out'; $resOld = Join-Path $b 'results\psm-results-old.csv'; $hist = Join-Path $b 'history.csv'
& $mk $shotOld 10; & $mk $logMid 10; & $mk $resOld 60; & $mk $hist 400
$c = Go @() -Extra @{ CleanupPreview = $true }
Check (($c -eq 0) -and (Test-Path $shotOld) -and (Test-Path $logMid) -and (Test-Path $resOld)) '-CleanupPreview deletes nothing and starts no test'
Check ($script:Calls -eq 0) '-CleanupPreview runs no test'
$c2 = Go @('PASS') -Extra @{ NoMail = $true }
Check ($c2 -eq 0) 'a history.csv with other columns does not stop the run'
Check (@(Get-ChildItem $b -Filter 'history-*.old.csv').Count -eq 1) 'the odd history file is kept aside, not overwritten'
Check (-not (Test-Path $shotOld)) 'a 10-day-old screenshot is removed (screenshot limit 7 days)'
Check (Test-Path $logMid) 'a 10-day-old log is kept (general limit 30 days)'
Check (-not (Test-Path $resOld)) 'a 60-day-old result file is removed'
Check (Test-Path $hist) 'history.csv is never removed, however old'
$e = Base-Env; $e.outputs = @{ keep_days = 0; screenshot_keep_days = 7 }; $h = New-Home $e $Csv1; $b = Base $h; $rd = Join-Path $b 'logs\runs\19990101-000000'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
$shotOld = Join-Path $rd 'row-1.screen.jpg'; $logOld = Join-Path $rd 'row-1.out'; & $mk $shotOld 10; & $mk $logOld 500
Go @('PASS') -Extra @{ NoMail = $true } | Out-Null
Check ((-not (Test-Path $shotOld)) -and (Test-Path $logOld)) 'keep_days 0 keeps logs forever, while the screenshot limit still applies'

Write-Host '7 no secrets in outputs'
$bad = 0; Get-ChildItem $b -Recurse -File | Where-Object { $_.Extension -ne '.lock' } | ForEach-Object { if ((Get-Content -Raw $_.FullName) -match '(?i)password') { $bad++ } }; Check ($bad -eq 0) 'no file contains the word password'

Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'psmt-*' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
Restore-TestEnv
Check (($env:PSMT_HOME -eq $script:OldHome) -and ($env:PSMT_ENV -eq $script:OldEnv)) 'the test left your PowerShell window as it found it'
Write-Host ("`n{0} checks passed, {1} failed" -f $script:Pass, $script:Fail)
exit $(if ($script:Fail) { 1 } else { 0 })
