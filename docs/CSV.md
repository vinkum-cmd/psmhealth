# tests.csv - what to put in it
One row = one test. Columns can be in any order; a column you don't need can be left out completely. Allowed characters in every cell: letters, digits and `. _ : @ / - space`.
An unknown column name stops the whole run. A blank cell takes its default from `envs\<name>\env.json` where a default is listed below.

## Needed in every row
| Column | Meaning | Example |
|---|---|---|
| `Connection-Component` | the connector to test; must be in `allowed_components` | `PSM-RDP` |
| `TargetAccountID` **or** `TargetAccount` + `TargetAccountSafe` | which account. The id is exact and used directly; without it the tool searches the safe for the user name | `12_34` / `windows-admin` + `WindowsTargets` |

**How the account is found:** `TargetAccountID` filled -> that account is read directly. Blank -> the safe is searched for `TargetAccount` (and `TargetAccountAddress` if given).
If a row has both an id and a `TargetAccount` / `TargetAccountAddress`, they must match the account behind the id, otherwise the row fails with "stale id or wrong row?". Filling both makes a row stable and self-checking.
Use the account's **real user name**, not its display name (the name shown in PVWA's account list can differ from the user name stored in the account). The id of every tested account is in the results file (column `AccountID`) and in the row log, so you can copy it into the CSV after a first run.

## Recommended
| Column | Meaning |
|---|---|
| `TargetPSMServer` | the PSM server name or IP the RDP window connects to; also checked (DNS + TCP 3389) before the row. Blank = `defaults.psm_server`, or the address PVWA returns (and no pre-check) |
| `TargetAccountAddress` | the account's address; use it when two accounts share a user name |
| `TargetServer` | the machine PSM connects to when it differs from the account's address (typical for domain accounts: the account address is the domain, the target server is the host) |
| `ExpectedTitle` | a window title text (max 80 characters) that must appear in the recording: proof the target was really reached. Leave blank for connectors that record no titles (SSH) |

## Defaults from env.json (leave blank unless this row differs)
`TargetPVWAUrl`, `TargetCCPUrl`, `PSMEnduser`, `EndUserSafe`, `EndUserApp-ID`, `EndUserObjectName`, `EndUser-Authentication-Method` (LDAP, Cyberark, RADIUS, Windows). Fill them only for a row that uses a different end user or CCP object.

## Optional per-row options
| Column | Values | Default |
|---|---|---|
| `HoldSec` | 10-900: seconds the session stays open | `test.hold_seconds` |
| `Retries` | 0, 1, 2 | `reliability.retries` |
| `Enabled` | yes / no (no = skipped, shown as "disabled") | yes |
| `DismissPromptAfterSec` / `DismissPromptCount` / `DismissPromptKey` | the one key that answers the PSM "OK" dialog: 0-120 seconds, 1-3 presses, `Enter` / `Y` / `A` only | the connector's profile in `prompt_defaults` |

## Not in the CSV (by design)
How the tool authenticates to CCP (certificate, Windows account), the manual credential option, the mail recipient and every command or key other than the three above live in `env.json` or on the command line - never in the CSV, so a changed test list can't redirect passwords or mail.

## Example (see `envs\example\tests.csv`)
```
Connection-Component, TargetAccount,         TargetAccountID, TargetAccountSafe, TargetServer,     ExpectedTitle
PSM-RDP,              windows-admin,         12_34,           WindowsTargets,    (blank),          Program Manager
PSM-SSH,              unix-user,             (blank),         UnixTargets,       (blank),          (blank)
PSM-WinScp,           unix-user,             12_35,           UnixTargets,       (blank),          (blank)
PSM-WebApp,           web-user@example.com,  12_36,           WebTargets,        app.example.com,  (blank)     HoldSec 150
```
The second row has no id, so the tool finds the account by safe and user name. Other columns (addresses, PSM server, retries) are omitted here.

## How to change things
* **Add a test:** add a row, then run `.\Run-PsmTests.ps1 -DryRun` - it prints every row with the values it would use and any error, and connects to nothing.
* **Add a connector:** see docs\CONNECTORS.md.
* **Change the hold time or key press:** for one connector edit its `prompt_defaults` profile; for one row fill the optional columns.
* **Turn a test off:** `Enabled = no`.
* **A different end user for one row:** fill `PSMEnduser`, `EndUserSafe`, `EndUserApp-ID`, `EndUserObjectName` in that row.
* **Run only some rows:** `-Only 2,3`.
