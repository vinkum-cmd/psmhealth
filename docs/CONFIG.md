# env.json - every setting
File: `envs\<name>\env.json`. It is only **read** (never executed). It is plain JSON: no comments and no trailing commas. A missing value falls back to the default shown. Change it, save, run again - nothing else to restart.

## Where things are
| Setting | Default | Meaning |
|---|---|---|
| `pvwa_url` | - | PVWA web address, used by rows that leave `TargetPVWAUrl` blank |
| `enduser.name` | - | the test end user (PVWA user) |
| `enduser.auth_method` | - | LDAP, Cyberark, RADIUS or Windows |
| `enduser.ccp.url` | `pvwa_url` | CCP web address |
| `enduser.ccp.app_id` / `safe` / `object` | - | the CCP AppID, and the safe and object that hold the end user's password |
| `defaults.psm_server` | blank | PSM server used by rows that leave `TargetPSMServer` blank (blank = the address PVWA returns, and no pre-check) |
| `target.account_safe` | blank | safe used by rows without `TargetAccountSafe` and without `TargetAccountID` |
| `allowed_components` | PSM-RDP, PSM-SSH, PSM-WinScp, WINSCP-SSH | the only connectors a CSV row may use |

## The test
| Setting | Default | Meaning |
|---|---|---|
| `test.hold_seconds` | 150 | seconds the session stays open (a row's `HoldSec` overrides) |
| `test.recording_wait_seconds` | 120 | how long to wait after the session for the recording to appear and close |
| `test.check_recording` | true | run the recording step at all |
| `test.min_recording_percent` | 0 | minimum recording length as % of the hold time minus the key-press delay; 0 = no length check |
| `test.check_window_titles` | true | fail on error window titles in the recording |
| `test.reason` | automated psm health test | base text of the reason sent to CCP and PVWA; the tool adds ` on <Day yyyy-MM-dd HH:mm:ss>` |
| `window_titles.error_anywhere` | Dispatcher error message, Fatal Error | a title containing one of these fails the row |
| `window_titles.error_if_last` | Warning, Security Alert | fails the row only if it is the last window shown (an unanswered prompt) |
| `prompt_defaults.<component>` | none | the one key press that answers the PSM "OK" dialog: `after_sec` (0-120), `count` (1-3), `key` (Enter, Y or A). A row can override with its `DismissPrompt...` columns |

## Reliability
| Setting | Default | Meaning |
|---|---|---|
| `prechecks.enabled` / `tcp_port` | true / 3389 | DNS + TCP check of the PSM server before a row |
| `reliability.retries` | 1 | repeat a failed row from the start this many times (a row's `Retries` overrides, 0-2) |
| `reliability.retry_wait_sec` | 60 | wait between attempts |
| `reliability.alert_after_failures` | 1 | failed runs in a row before the first FAILED alert |
| `reliability.max_run_minutes` | 60 | a run lock older than this counts as stale and is replaced |
| `reliability.heartbeat_hours` | 0 (off) | `-HeartbeatCheck` alerts when the last run finished longer ago than this |

## Credentials to CCP
| Setting | Default | Meaning |
|---|---|---|
| `credentials.ccp.client_certificate_thumbprint` | blank | present this client certificate to CCP (AppID authentication by certificate serial number). Looked up in `CurrentUser\My` and `LocalMachine\My`; needs a private key and must not be expired |
| `credentials.ccp.windows_integrated` | false | call CCP as the Windows account running the script (AppID authentication by OS user) |
Both blank/false = only the AppID's allowed machine (IP address) is used. Path and hash authentication belong to the local Credential Provider and are not supported. These settings are never in the CSV.

## Mail
| Setting | Default | Meaning |
|---|---|---|
| `mail.smtp_host` / `smtp_port` | - / 25 | mail server. The tool sends plain, anonymous SMTP (no TLS, no login); a server that requires either is not supported |
| `mail.from` / `mail.to` | - | sender and the list of recipients - the only place recipients come from |
| `mail.send_on` | failure | `always` = every run mails; `failure` = only FAILED / STILL FAILING / RECOVERED |
| `mail.repeat_hours` | 6 | how long before a still-failing test alerts again |
| `mail.subject_prefix` | [PSM health] | start of every subject |
| `mail.dry_run` | false | true = print the mail on screen instead of sending, and do not change the alert memory |

## Screenshots
| Setting | Default | Meaning |
|---|---|---|
| `screenshots.mode` | off | `off`, `failures` (keep the picture only when the row failed) or `all`. `-Screenshots` overrides |
| `screenshots.interval_sec` | 5 | take a picture every N seconds (minimum 2); the last one is kept |
| `screenshots.max_mail_kb` | 3000 | pictures embedded in one mail; the rest stay on disk (0 = no limit) |

## Outputs and cleanup
| Setting | Default | Meaning |
|---|---|---|
| `outputs.json` | true | also write the results JSON |
| `outputs.history` | true | append to `history.csv` |
| `outputs.keep_days` | 30 | delete results, logs and traces older than this; 0 = keep forever |
| `outputs.screenshot_keep_days` | = keep_days | delete screenshots older than this; blank = same as `keep_days`; 0 = keep forever |
| `outputs.eventlog` | false | write a Windows Application event per run (an admin registers the source once: `New-EventLog -LogName Application -Source PSMHealthTest`) |
| `outputs.webhook_url` | blank | post the run totals (no secrets) to this web address |

## Ignored settings
`test.check_audit`, `reliability.row_timeout_sec`, `target.component`, `target.account`, `target.server`, `environment`, `schema` are not used by the Windows tool; they may stay in the file.

## Environment variables
* `PSMT_ENV` - selects the environment folder by name (the same as `-Environment`). If a stale one is set in your PowerShell window you will see "environment 'x' not found"; clear it with `Remove-Item Env:PSMT_ENV`.
* `PSMT_MAIL_DRYRUN=1` - print mails instead of sending them.
* `PSMT_HOME` - used only by the self-test; a real run removes it and always reads its settings from its own folder.
