# PSM health test - Windows runner (version 2.1.0)

Opens a real PSM session for every test row, holds it, and proves the whole chain works:

**CCP password -> PVWA logon -> target account -> PSMConnect -> RDP session to the PSM server -> recording stored, closed, no error window (and the expected window title seen).**

It writes results (CSV + JSON), a history file and a status file, can keep the last screenshot of each session (a setting), and sends one summary mail per run to the recipient in `env.json`.
The only input the tool ever sends into a session is **one fixed key press** (Enter, Y or A, chosen per connector from a table written in the code), used to answer the PSM server's "OK" dialog. Nothing in a CSV or setting can add a key or a command (docs\SECURITY.md).
Proven with RDP, SSH and WinSCP connectors and a browser-based web connector. More can be added with configuration only (docs\CONNECTORS.md).

## Requirements
* Windows PowerShell 5.1. An interactive PowerShell window is already in the single-thread mode (STA) that the RDP window needs; from another program or a scheduled task start it as `powershell.exe -STA -File ...`.
* An **interactive, unlocked desktop** for the account that runs it: the test opens an RDP window, presses one key and takes screenshots. A locked screen, a minimized or disconnected Remote Desktop session, or a background (non-interactive) task cannot work. See docs\SCHEDULE.md.
* Network access to the PVWA/CCP web address, the PSM server (TCP 3389) and the mail server (default TCP 25).

## Quick start
Copy the folder to the test host (for example `C:\psm-test`). If the files came from a download or a share, unblock them once: `Get-ChildItem C:\psm-test -Recurse | Unblock-File`.

    cd C:\psm-test                                           # the folder you installed the tool in
    .\tests\Test-Selftest.ps1                                 # offline self-test of the tool itself (opens no session, sends no mail)
    .\Run-PsmTests.ps1 -Validate                              # checks host, rows, PSM server ports, PVWA/CCP, mail - opens no session
    .\Run-PsmTests.ps1 -DryRun                                # shows what every row would use - connects to nothing
    .\Run-PsmTests.ps1 -Only 1 -NoMail -Trace                 # first live run of one row, with a detailed trace file
    .\Run-PsmTests.ps1                                        # all rows, mail per env.json

A new environment (another site or PVWA): `Copy-Item -Recurse envs\example envs\prod`, edit `envs\prod\env.json` and `tests.csv`, then use `-Environment prod`.

## Commands (switches)
| Switch | What it does |
|---|---|
| `-Environment <name>` | which folder under `envs\` to use. Default: the only one besides `example`, or `$env:PSMT_ENV` |
| `-Only 1,3` | run only those CSV rows (numbered in file order; quotes optional, no space after the comma) |
| `-Csv <file>` | use another CSV instead of `envs\<name>\tests.csv` |
| `-Hold <seconds>` | override the hold time for this run (testing) |
| `-NoMail` | run, but send no mail |
| `-DryRun` | print each row with the values it would use; connect to nothing |
| `-Validate` | checklist: host, rows, PSM servers (DNS + TCP), PVWA/CCP reachable, CCP authentication settings, mail port |
| `-Trace` | write `row-N.trace.log` per row: every web call (method, address, code, ms), step timings, the RDP timeline with clock times, recording polls and the recorded window titles. Never passwords, tokens or request bodies |
| `-Screenshots off\|failures\|all` | override `screenshots.mode` for this run |
| `-Manual` | ask for a user name and password (hidden) instead of CCP; one credential for every row, memory only, asked again next run |
| `-Credential (Get-Credential)` / `-Credential <user>` | the same, supplied up front (`-Credential <user>` asks for the password hidden). There is deliberately **no** plain-text password parameter |
| `-Pause` / `-Resume` | kill switch: while paused every run refuses to start (exit code 4) |
| `-HeartbeatCheck` | alert if no run finished within `reliability.heartbeat_hours` (for its own scheduled task; needs no desktop) |
| `-CleanupPreview` | list the old files the next run would delete, with age and size; deletes nothing, starts no test |
| `-TestMail` | send one harmless test mail; shows the underlying cause if it fails |
| `-Resend <results.csv>` | rebuild and send the report mail for an old results file |
| `-Version` | print the version |

Exit codes: **0** all tests passed (or the requested action succeeded), **1** a test failed, **2** `-HeartbeatCheck` found that no run finished in time, **3** another run is active, **4** paused, **5** manual credentials missing or invalid.

## What you get after a run (`envs\<name>\`)
| File | Content |
|---|---|
| `results\psm-results-<RunId>.csv` / `.json` | one line per test: the values used, result, failed step, reason, the six step statuses, recording id and length, account id, screenshot path, attempts, log path, suggested fixes |
| `logs\runs\<RunId>\row-N.out` | the step-by-step log of each row (`-tryK` for retries) |
| `logs\runs\<RunId>\row-N.trace.log` | the trace (only with `-Trace`) |
| `logs\runs\<RunId>\row-N.screen.jpg` | the last picture of the session while it was open |
| `history.csv` | one line per test per run, for trends (never deleted) |
| `status.json` | the latest run (read by `-HeartbeatCheck`) |
| `logs\mail-state.json` | the alert memory per test (never deleted) |

Old results, logs and traces are deleted after `outputs.keep_days` (default 30), screenshots after `outputs.screenshot_keep_days` (blank = same as `keep_days`; the example environment uses 7).

## The mail
One mail per run to the recipient in `env.json` (`mail.to`, never from the CSV). With `send_on: always` every run mails; with `failure` only changes mail (FAILED / STILL FAILING / RECOVERED).
It contains the table (tick or cross per step), each failure with reason and suggested fixes, the screenshots inside the page, the tool version and fingerprint, and the results CSV attached.

## How it is organised
* `Run-PsmTests.ps1` - the entry point (switches, fingerprint, loads the libraries).
* `lib\Core.ps1` - everything except the session: settings, CSV rules, alert memory, lock, history, cleanup, checks, report and mail, run flow.
* `lib\Engine.ps1` - one test: the six steps, and the RDP window code with the fixed key table.
* `envs\<name>\env.json`, `tests.csv` - all site-specific values and the test list.
* `tests\Test-Selftest.ps1` - the offline self-test (uses a pretend session and pretend mail).
* `Sign-Scripts.ps1`, `Make-Release.ps1` - signing and packaging helpers.

## Documents
| | |
|---|---|
| docs\HOW-IT-WORKS.md | what happens in a run, step by step (A setup, B per row, C after) |
| docs\CONFIG.md | every setting in `env.json` |
| docs\CSV.md | the test list: columns, what is required, how to change |
| docs\CONNECTORS.md | the connector types proven, the OK key press, recorded titles, adding a new connector |
| docs\SECURITY.md | what the tool protects, what it does not, how to lock it down |
| docs\SCHEDULE.md | running it on a schedule (desktop requirements) |
| docs\TROUBLESHOOTING.md | error messages and what to do |
| docs\CHANGELOG.md | what changed in each version |
