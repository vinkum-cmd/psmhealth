# Security
What the tool protects, what it does not, and how to lock it down.

## What the tool does to protect itself
| Area | Control |
|---|---|
| **Input into sessions** | The only thing ever sent into a PSM session is **one key** from a fixed table written in `lib\Engine.ps1` (Enter, Y, A), at most 3 presses, 0-120 seconds after connecting, every press logged. No CSV cell, setting, command-line switch or environment variable can add a key or a command. |
| **Passwords** | From CCP at run time, held in memory only; or typed with `-Manual` / `-Credential` and held as an encrypted SecureString for the run. Handed straight to the RDP control and the logon call. Never written to disk, Credential Manager, command line, log, trace, result file or mail. There is no plain-text password parameter. The working copy is cleared before the RDP window opens and when the test ends. |
| **Configuration** | `env.json`, `tests.csv` and the settings are only **read** (parsed as data), never executed. Every CSV cell is limited to letters, digits and `. _ : @ / - space`; unknown columns are refused; components must be in `allowed_components`; key and number ranges are checked. |
| **Where mail goes** | Only to `mail.to` in `env.json`. The CSV and the command line cannot change it. |
| **Where settings come from** | A real run always reads its own folder (`PSMT_HOME`, used only by the self-test, is removed at start). `-Environment` / `PSMT_ENV` can only pick a folder name under `envs\` (letters, digits, `_`, `-`). |
| **Which code ran** | Every run prints, and puts in the mail, a SHA256 fingerprint over the three script files. A changed file gives a different fingerprint. |
| **Audit trail** | Each CCP request and each PSMConnect carries the reason `<text> on <Day date time>`, so every entry in the CCP and PVWA audit logs can be matched to a run. |
| **One run at a time** | A lock per environment, a kill switch (`-Pause`), a heartbeat that alerts when runs stop. |
| **Data kept** | Results, logs and traces for `outputs.keep_days` (default 30 days); screenshots for `outputs.screenshot_keep_days` (blank = the same limit); history and state files stay. `-CleanupPreview` shows what is next. |

## What it does not protect against
* **An administrator on the test host** can always change the scripts, the settings or the memory of a running process. The controls below make that harder and visible; they cannot make it impossible.
* **Anyone with write access to the script folder** can change what the tool does. The fingerprint shows it only afterwards.
* **Screenshots can show sensitive content** of privileged sessions. They are mailed to the configured recipient over plain, anonymous SMTP (the tool does not use TLS) and kept on the host for the retention period.
* **CCP trust by IP address** (the current AppID method): a copy of the scripts run on the same host, or from another machine with the same address, would be accepted. A client certificate or the Windows account (`credentials.ccp`) ties it to an identity.
* The test user's PVWA/CCP rights decide what a stolen test credential could do: keep them minimal.

## Lock-down checklist (not all done yet)
1. **Dedicated run account**, not an administrator; one end user per test host (a second logon of the same end user ends the other's API session).
2. **Folder permissions** (suggestion; adapt the names): the run account gets *read and execute* on the whole tool folder, and *modify* only where the tool writes - `envs\<name>\logs`, `envs\<name>\results`, and the files `history.csv`, `status.json`, `run.lock`, `PAUSE`, `heartbeat-alert.json` in the environment folder. `env.json`, `tests.csv`, `Run-PsmTests.ps1`, `lib\*.ps1` stay read-only for it. Example (not run):
   `icacls C:\psm-test /inheritance:r /grant "DOMAIN\Admins:(OI)(CI)F" "DOMAIN\psm-test-run:(OI)(CI)RX"`
   `icacls C:\psm-test\envs\<name>\logs /grant "DOMAIN\psm-test-run:(OI)(CI)M"` (and the same for `results`, plus modify on the individual state files)
3. **Sign the scripts**: `.\Sign-Scripts.ps1` (needs a code-signing certificate), then set the execution policy to **AllSigned** for that account. Any edit breaks the signature and the script refuses to run. Re-sign after every approved change. *Not done yet.*
4. **Optional:** an AppLocker / WDAC rule that allows only your signer.
5. **CCP client certificate or Windows account** instead of IP trust (settings exist in `credentials.ccp`; needs an AppID set up for it).
6. **Mail:** keep the mail path on a trusted network (the tool sends plain SMTP), or turn screenshots off / to `failures` if the recipient mailbox or the path is not trusted enough for pictures of privileged sessions.
7. Keep the release package's checksum (`Make-Release.ps1` writes it) to verify a copy of the tool.
