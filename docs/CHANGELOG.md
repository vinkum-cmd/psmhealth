# Changelog

## 2.1.0 - 2026-11-01
New:
* `-Manual` / `-Credential`: manual end-user credentials (one per run, SecureString in memory, asked again each run).
* `-Trace`: per-row trace file (web calls, step timings, RDP timeline with clock times, recording polls, recorded window titles); never secrets.
* `TargetAccountID` column: use the account id directly; otherwise search by user name, address and safe. Results column `AccountID`.
* Reason sent to CCP and PVWA now ends with the day and time (`... on Sunday 2026-11-01 02:18:36`).
* Screenshots: the last picture of every session, embedded in the mail (`screenshots` in env.json, `-Screenshots`); results column `Screenshot`.
* `ExpectedTitle` proven live for the RDP, WinSCP and web connectors.
* Mail on success too (`mail.send_on: always`; subject `ALL OK (n tests)`).
* `credentials.ccp`: CCP client-certificate and Windows-account authentication options (set in env.json, never in the CSV).
* Cleanup limits: separate `outputs.screenshot_keep_days`; `-CleanupPreview`.
* Connector profile for a browser-based web connector (Enter after 10 s); RDP, SSH, WinSCP and the web connector all proven live.
* Documentation: CONFIG, SECURITY, CONNECTORS, SCHEDULE, TROUBLESHOOTING, HOW-IT-WORKS rewritten.
Fixed:
* The TCP port check read only the first character of a single address (false "3389 not reachable").
* `-Only 2,3` failed because the switch was a single text value.
* The self-test left `PSMT_ENV` / `PSMT_HOME` set in the PowerShell window; it now restores them, and a real run ignores `PSMT_HOME`.
* Empty `[extra auth: ]` text in the trace.
* A `history.csv` with other columns stopped the whole run before the mail. Now it is kept aside (`history-<time>.old.csv`) and a new one is started; a failure to write the history, JSON or status file only produces a warning.
* The default list of allowed connectors was different in two places; both now include `WINSCP-SSH`.

## 2.0.0 - 2026-10-31
* Windows runner rebuilt on the environment design: `envs\<name>\env.json` + `tests.csv`, one row per test with per-row hold time, retries, enabled, expected title.
* Pre-check of the PSM server, retry, alert-after-N-failures, run lock, kill switch, heartbeat, results CSV + JSON, history, status, cleanup, `-Validate`, `-DryRun`.
* Offline self-test with a pretend session and pretend mail.
* The one fixed key press (Enter) that answers the PSM server's "OK" policy dialog.
