# Troubleshooting
First, for any problem: run the row alone with a trace - `.\Run-PsmTests.ps1 -Only <n> -NoMail -Trace` - and read `envs\<name>\logs\runs\<RunId>\row-N.trace.log` (every web call with its code and time, each step, the RDP timeline with clock times, the recorded window titles) and the screenshot `row-N.screen.jpg`.

## Starting
| Message | Meaning / what to do |
|---|---|
| `no environment selected: use -Environment <name> ...` | there is no folder under `envs\` besides `example`, or more than one: create one (`Copy-Item -Recurse envs\example envs\prod`) or name it with `-Environment` |
| `environment 'x' not found: ...` | the name from `-Environment` or `$env:PSMT_ENV` has no folder under `envs\`. If you didn't ask for it, a stale `PSMT_ENV` is set in this PowerShell window: `Remove-Item Env:PSMT_ENV` |
| `another run is active (lock ...) - not starting` (exit 3) | a run is going, or crashed; a lock older than `max_run_minutes` (60) is replaced automatically |
| `environment '<name>' is PAUSED (remove with -Resume) - not starting` (exit 4) | someone ran `-Pause`; `-Resume` removes it |
| `the RDP window needs an STA thread` | start with `powershell.exe -STA -File ...` |
| PowerShell says the file "is not digitally signed", "running scripts is disabled" or the file is blocked | a script from a download or share is blocked: `Get-ChildItem <folder> -Recurse \| Unblock-File`. If your policy requires signed scripts, sign them (docs\SECURITY.md) - do not switch the policy off |
| `no credentials entered - not starting` (exit 5) | `-Manual` / `-Credential` with an empty password, or a user name with characters other than letters, digits and `. _ : @ / -` |
| `WARNING: history.csv had other columns; it was kept as ...` | an old or edited history file did not match the current columns; it was set aside untouched and a new history started. Nothing to fix |
| `WARNING: ... could not be written` | a results, JSON, status or history file could not be written (disk full, no permission, file open in another program); the run continues and the mail is still sent. Fix the folder permissions or space |
| `CSV: unknown column(s) ... - refusing to run` | a column name is not in the list (docs\CSV.md); fix or remove it |
| a row fails at step `input` | the row's reason names the cell (characters, `HoldSec` 10-900, `Retries` 0-2, `Enabled`, key, component not in `allowed_components`, malformed `TargetAccountID`) |

## Step by step
| Step | Message | What to do |
|---|---|---|
| precheck | `PSM server ... not reachable on TCP 3389` / `does not resolve in DNS` | check the name, firewall and the PSM service |
| ccp | `CCP http=401/403 ... (authentication sent: ...)` | the AppID is not allowed for this machine/certificate/account: AppID > Authentication in PVWA. The message names what was sent |
| ccp | `CCP username '...' differs from PSM_USER` | the CCP object belongs to another user |
| ccp | `CCP client certificate ... not found / has no private key / expired` | install the certificate for the account that runs the test; check the thumbprint (`-Validate` shows it) |
| logon | `REST logon (LDAP) http=401 ...` | wrong password in the CCP object, user locked/suspended, method not allowed, or PVWA `AllowAPIAccess` |
| account | `target account '...' not visible in safe ...` + hints | wrong safe, display name instead of user name, or no List accounts on the safe; the message lists what the end user can see |
| account | `TargetAccountID 12_34 is account 'x', but the CSV says 'y'` | stale id or wrong row |
| connect | `PSMConnect (...) http=...` | component not assigned to the platform, no Use accounts, dual control, PSM server not registered |
| session | `RDP never connected to ... within 60s` | PSM server unreachable or refusing; check 3389 and NLA |
| session | `RDP session was closed by the server after N s (hold M s)` | the session ended early. Most common: the **OK dialog was not answered** (no/late key press: check `prompt_defaults` and the `-Trace` timeline), or the connector failed inside (read the PSM server's newest component log for that session) |
| recording | `no recording from this session visible within ...s` + list | recording not stored, or in a safe the end user cannot read (PSMRecordings safe rights), or the connector never started. The list shows what was visible |
| recording | `Recordings API http=401/404` | the end user lost its API session (the same user logged on elsewhere) or lacks rights; the tool re-logs on twice before failing |
| recording | `session still live ... after disconnect` | the session did not close; check disconnected-session limits |
| recording | `expected window title 'X' not seen in the session` | the target was not reached (e.g. still on a sign-in page) or the title text is wrong: read the `title:` lines in the trace |
| recording | `error window in the session: ...` | a dialog with Warning/Error/Fatal text appeared; look at the screenshot |

## Screenshots
| Situation | Meaning |
|---|---|
| log says `no usable screenshot` | the screen was locked or blank, or nothing was drawn. Keep the desktop unlocked; if you are connected to the host over Remote Desktop, keep that window open, not minimized and large enough for the 1024x768 test window (for example 1280x800) |
| the picture is cut off | the host's display is smaller than the 1024x768 window |
| the mail has fewer pictures than rows | the `screenshots.max_mail_kb` limit; the rest are on disk |
| pictures vanish | cleanup: `outputs.screenshot_keep_days`; `-CleanupPreview` shows what is next |

## Mail
| Situation | What to do |
|---|---|
| `mail: not sent` | `-NoMail`, or no `smtp_host` / `to` in env.json |
| `WARNING: mail could not be sent` | run `-TestMail`: it prints the underlying cause (mail port blocked, server down, a server that requires TLS or a login). Failed alerts are retried by the next run; use `-Resend` for an old report |
| no mail for a failure | `alert_after_failures` holds back the first failures; a repeat inside `repeat_hours` stays quiet |
| too many mails | `mail.send_on: failure` |

## The self-test
`.\tests\Test-Selftest.ps1` must end with "N checks passed, 0 failed". A failed line names the behaviour that broke - send it with the output when asking for help. It uses temporary folders and restores your PowerShell window's variables afterwards.
