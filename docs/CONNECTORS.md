# Connectors
What to expect from the connector types the tool has been proven with, and how to add another. The recorded window titles below were read with `-Trace`; your environment may differ - always check a new row with `-Trace` first.

| Connector type | Typical OK key press | What PSM records (window titles) | Choosing `ExpectedTitle` | Notes |
|---|---|---|---|---|
| **RDP** (`PSM-RDP`) | Enter after about 10 s | `explorer.exe, Program Manager`, often `ServerManager.exe, Server Manager` | `Program Manager` (the Windows desktop shell has loaded, so the logon really happened) | For domain accounts the account address is the domain: set `TargetServer` to the host. |
| **SSH** (`PSM-SSH`) | Enter after about 10 s | **nothing** - SSH sessions record no window titles | leave blank | The screenshot (a terminal with a prompt) is the evidence. |
| **WinSCP** (`PSM-WinScp`) | Enter after about 20 s | several windows in order: a "Show Login Window" entry, `Login`, `Server prompt`, then the main window titled `<folder> - <user>@<host> - WinSCP` | text that appears only in the **main** window (for example the remote folder name) | The earlier windows also say WinSCP, so choose text that the login and prompt windows don't contain. |
| **Web connector** (a browser sign-in connector, e.g. `PSM-WebApp`) | Enter after about 10 s | browser window titles: the sign-in page, a redirect page, then the page shown after sign-in | the title of the page shown **after** sign-in (never the sign-in page's title) | Takes about a minute; use `HoldSec` of 90 or more. The account must not need MFA. Recording protocol shows as HTTP. |

The delays are starting points. Tune them with `-Trace`: its timeline shows when the window connected and when the key was pressed.

## Why there is a key press
The PSM server shows an "OK" policy dialog at the start of every session, and it must be answered before PSM logs on and starts recording. When an exception for the test user is not possible, the tool presses **one fixed key** (Enter) after a set number of seconds. The key table is written inside `lib\Engine.ps1` (Enter, Y, A only, at most 3 presses); no CSV, setting or command line can add another key or a command.

**If the key press is missing or at the wrong time,** the session waits at the dialog and the PSM server closes it after about two minutes: you see "RDP session was closed by the server after ... s" and no recording. Fix: give the connector a profile in `prompt_defaults` and check the delay with `-Trace`.

## Adding a connector
1. In PVWA make sure the connection component works by hand and is assigned to the account's platform.
2. `env.json`: add its ID to `allowed_components`; add `prompt_defaults.<ID>` = `{ "after_sec": 10, "count": 1, "key": "Enter" }` (the OK dialog applies to every session).
3. `tests.csv`: add a row (docs\CSV.md). Use the account's real user name and fill `TargetAccountID` if you know it.
4. Run `.\Run-PsmTests.ps1 -Only <n> -NoMail -Trace`. Open the screenshot and read the `title:` lines in the trace.
5. Choose an `ExpectedTitle` that appears **only when the target is really reached** (not on a sign-in page), put it in the CSV and run again.
6. For web connectors use `HoldSec` of 90 or more and an account without MFA: an unattended test cannot answer it.
