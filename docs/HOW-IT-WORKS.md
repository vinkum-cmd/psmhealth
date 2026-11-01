# What happens in a run, in order (Windows runner)
The steps of a run, in the order they happen. Each step names the file and function so you can read the code next to it.

## A. Before any row (setup)
| # | What happens | Where |
|---|---|---|
| A1 | PowerShell starts the script and reads the switches you typed (`-Only 1`, `-NoMail`, `-Validate` ...). Nothing is connected yet. | Run-PsmTests.ps1 `param(...)` |
| A2 | It finds its own folder, reads the version, and computes one SHA256 over the three script files (this goes into the mail so you can prove which code ran). | Run-PsmTests.ps1 (top of the script) |
| A3 | It loads the two library files into memory: Core.ps1 (everything except the session) and Engine.ps1 (the session itself). It only defines functions; nothing runs yet. | Run-PsmTests.ps1 (top of the script) |
| A4 | It prints the banner and hands all switches to `Invoke-Cli`, which decides what to do. | Run-PsmTests.ps1 (top of the script), Core.ps1 `Invoke-Cli` |
| A5 | It picks the environment folder (`envs\<name>`), reads `env.json` and the mail settings, and creates the `logs` and `results` folders. | `Get-EnvName`, `Load-Environment` |
| A6 | It turns env.json into run settings (hold time, recording wait, allowed components, title lists, mail prefix). | `Set-RunVars` |
| A7 | It reads `tests.csv`, checks every row (allowed characters, allowed component, numbers in range), fills blanks from env.json and from the connector profile (the Enter press). A bad row is marked with its error and will fail as "input". | `Read-Rows` |
| A8 | Early exits, in code order. Right after A6, before the CSV is read: `-Pause`/`-Resume`, `-TestMail`, `-HeartbeatCheck`, `-CleanupPreview`, `-Resend` each do one job and return. After A7: `-Only` keeps just the listed rows, `-Validate` prints the checklist and returns, `-DryRun` prints the rows and returns. A normal run continues to A8b. | `Invoke-Cli` |
| A8b | With `-Manual` it asks once for the user name and password (hidden dialog); with `-Credential` it uses what you passed. That user replaces the CSV end user for every row and the mail says the credentials were manual. Nothing is saved: the next run asks again. Without them, passwords come from CCP per row. | `Invoke-Cli` |
| A9 | Refuses to start if the environment is paused (`PAUSE` file) or another run holds `run.lock`; otherwise takes the lock. | `Invoke-Run`, `Acquire-Lock` |

## B. For each row (repeat per enabled row)
| # | What happens | Where |
|---|---|---|
| B1 | Pre-check: DNS (IPv4) and TCP 3389 to the CSV's PSM server (skipped when the row has no TargetPSMServer). If it fails, the row fails at once and no session is opened. Happens once per row, before the attempts. | `Invoke-Row`, `Test-PsmServer` |
| B2 | CCP step: fetch the end user's password from CCP into memory. With `-Manual`/`-Credential` there is no CCP call: the password typed at the start of the run (kept as a SecureString) is used instead, for every row. | Engine.ps1 `Step 'ccp'` |
| B3 | Logon step: PVWA REST logon with that password. | `Step 'logon'` |
| B4 | Account step: with `TargetAccountID` in the row, read that account directly (and check user/address match if also given); otherwise list the safe and pick the account by user name (+ address). | Engine.ps1 `Step 'account'` |
| B5 | Connect step: PVWA PSMConnect (reason = base text + day and time; PSMRemoteMachine added when TargetServer differs from the account address) returns an RDP file (PSM address, user, shell). No ConnectionType is sent. | `Step 'connect'` |
| B6 | Session step: open the RDP window to the PSM server (the CSV's TargetPSMServer wins over the address PVWA returned), press the one fixed key (Enter) after N seconds, if screenshots are on, take a picture every few seconds and keep the last one, hold for the hold time, disconnect. | `Step 'session'`, `Initialize-Rdp`, C# `PsmRdp.Run` |
| B7 | Recording step: poll for the recording (user + account + component, started after this test began) until it is closed (waiting up to `recording_wait_seconds`), then check ExpectedTitle and the error window titles. | `Step 'recording'` |
| B8 | Retry: a failed attempt (not input errors, not a failed pre-check) is repeated from the start after retry_wait_sec, up to 1 + Retries attempts; the last attempt decides. Each attempt has its own log, trace and screenshot files. | `Invoke-Row` |

## C. After all rows
| # | What happens | Where |
|---|---|---|
| C1 | Write results CSV (standard columns + steps, AccountID, Screenshot, RecordingId, Attempts ...), results JSON, history.csv, status.json (optional event log / web hook). | `Invoke-Run` |
| C2 | Delete files older than their limit: `outputs.keep_days` (default 30) for results, logs and traces, `outputs.screenshot_keep_days` (the example uses 7) for screenshots. 0 = keep forever. Never deletes history.csv, status.json, mail-state.json, heartbeat-alert.json. `-CleanupPreview` shows what would go. | `Get-OldFiles`, `Remove-OldFiles` |
| C3 | Alert decision per test from the saved state (FAILED after alert_after_failures, STILL FAILING every repeat_hours, RECOVERED), build one HTML+text mail (table, failures with fixes, screenshots, CSV attached), send to the env.json recipient, save the state. send_on=always mails every run. | `Decide-Alert`, `Build-Report`, `Send-Report` |
| C4 | Release the lock (always, in a finally block) and return the exit code: 0 all passed, 1 a test failed, 2 `-HeartbeatCheck` found no recent run, 3 another run active, 4 paused, 5 manual credentials missing/invalid. | `Invoke-Run`, main script |

## Debugging: -Trace
`Run-PsmTests.ps1 -Only 4 -NoMail -Trace` writes `logs\runs\<run id>\row-N.trace.log` next to the normal row log: every web call (method, address, answer code, milliseconds, which extra CCP authentication was sent), the pre-check, each step with its duration, the PSM address returned, the RDP window timeline (connect requested, connected, key pressed, hold complete, disconnected or server closed the session, each with its second), each recording poll, and the window titles PSM recorded for the session (first 25, cut to 90 characters - useful for choosing `ExpectedTitle`). It never records passwords, tokens, headers, request bodies, CCP answers or the contents of the PSM connection file. Off by default.

## Screenshots
`env.json` `screenshots`: `mode` (`off`, `failures`, `all`; command line `-Screenshots` overrides), `interval_sec` (picture every N seconds, min 2), `max_mail_kb` (embedded pictures per mail, rest only on disk). In B6 the RDP window code copies the window's screen area every N seconds into memory (JPEG, quality 70) and, when the session ends or the server closes it, writes the latest picture to `row-N.screen.jpg`. Blank pictures (locked screen, nothing drawn) are discarded. After the row, in `failures` mode a passed row's picture is deleted. The mail (C3) embeds the pictures as inline images.
