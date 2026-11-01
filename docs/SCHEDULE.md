# Scheduling (Windows Task Scheduler)
The tool does not install a schedule itself; runs can be started by hand or by a task you create. This page explains the requirements and gives a template.

## The requirement that decides everything: an interactive, unlocked desktop
The test opens an RDP window, presses one key in it and photographs it. All three need a real desktop session that is signed in, unlocked and drawing.

| Task / session situation | Works? |
|---|---|
| Task **"Run only when user is logged on"**, the account signed in at the console (or in a connected, not minimized, Remote Desktop session), screen unlocked | **Yes** |
| Task **"Run whether user is logged on or not"** (background session, no desktop) | **No.** No window, no key, blank pictures. Use it only for `-HeartbeatCheck` |
| Screen locked, screensaver running | **No.** The key and the picture go to the lock screen |
| Remote Desktop session **disconnected** (closed without signing out) or the RDP client minimized | **Unreliable / no.** The session may stop drawing |
| `-Manual` | **Never scheduled:** it asks for a password |

## Recommended setup
* A dedicated **non-admin Windows account** on a host used for this, signed in automatically at the **console** (a VM console, not an RDP connection), screensaver and inactivity lock turned off for it.
* Task: "Run only when user is logged on", action `powershell.exe -STA -NoProfile -File "...\Run-PsmTests.ps1"` (add `-Environment <name>` if there are several), do not start a new instance while one runs (the tool's own run lock also protects), stop after 1 hour.
* A run takes roughly (number of rows) x (hold time + 20-30 seconds), plus waits for retries. For example 4 rows with a 150-second hold take about 11 minutes. Schedule no more often than that, with margin; the run lock refuses an overlapping run.
* The RDP window opens on top, 1024x768, for about the hold time per row, so nobody should use that desktop for other work.
* If CCP authentication moves to a certificate or the Windows account, that certificate / account must be the task's account.
* With `send_on: always` a mail is sent at every run (48 a day at a 30-minute schedule). Set `mail.send_on` to `failure` to mail only changes.

## Template (edit, run once as admin; NOT installed automatically)
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-STA -NoProfile -File "C:\psm-test\Run-PsmTests.ps1"'
    $t = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 30)
    $p = New-ScheduledTaskPrincipal -UserId 'DOMAIN\psm-test-run' -LogonType Interactive
    Register-ScheduledTask -TaskName 'PSM health test' -Action $a -Trigger $t -Principal $p -Settings (New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1))

**Heartbeat:** a second task, hourly, with `-HeartbeatCheck`, may run whether anyone is signed in or not (it needs no desktop), for example as a service account that can read the environment folder and reach the mail server. It alerts when no run has finished within `reliability.heartbeat_hours` (6).
**Pause everything:** `.\Run-PsmTests.ps1 -Pause` (and `-Resume`). Optional Windows event log entries: `outputs.eventlog` (register the source once: `New-EventLog -LogName Application -Source PSMHealthTest`).

## Idea, not built
A "desktop ready?" check at the start of a run, which would fail in a second with a clear message and mail when the session is not interactive or the screen is locked, instead of failing about two minutes later.
