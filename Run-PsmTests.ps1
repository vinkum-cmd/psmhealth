<#
.SYNOPSIS
  PSM health test (Windows runner, v2). One CSV row = one test: CCP password -> PVWA logon -> target account -> PSMConnect -> RDP session to the
  PSM server held for the hold time -> recording check. Writes results (CSV + JSON), history and status; sends ONE summary mail per run per the alert policy.
.EXAMPLE
  powershell.exe -STA -File .\Run-PsmTests.ps1 -Validate          # check everything without opening a session
  powershell.exe -STA -File .\Run-PsmTests.ps1 -Only 1 -NoMail    # first live check
.NOTES
  Passwords come from CCP at run time and live only in memory. The only input ever sent into a session is ONE key from the fixed table in
  lib\Engine.ps1 (Enter / Y / A, max 3 presses, every press logged). CSV/JSON are validated and only read, never executed.
  Sign Run-PsmTests.ps1 and lib\*.ps1 and run under AllSigned (see README.md). Needs Windows PowerShell 5.1 in an interactive desktop session.
#>
[CmdletBinding()]
param(
  [string]$Environment = '',     # folder under envs\ (default: the only one besides "example", or $env:PSMT_ENV)
  [string]$Csv = '', [string[]]$Only = @(),     # e.g. -Only 1,3  (quotes optional)
  [int]$Hold = 0,                # override hold seconds for this run (testing), 0 = env.json / CSV
  [switch]$NoMail, [switch]$DryRun, [switch]$Validate, [switch]$Pause, [switch]$Resume, [switch]$HeartbeatCheck, [switch]$TestMail,
  [string]$Resend = '', [switch]$Version,
  [ValidateSet('', 'off', 'failures', 'all')][string]$Screenshots = '',   # which sessions get a screenshot in the mail (default: env.json screenshots.mode)
  [switch]$CleanupPreview,        # list the old files the next run would delete (deletes nothing, starts no test)
  [switch]$Trace,                # detailed per-row trace files (no secrets ever); off by default
  [switch]$Manual,               # ask for a user name + password (hidden) instead of CCP; one credential for ALL rows of this run, memory only, asked again next run
  [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential   # or pass it: -Credential (Get-Credential)  /  -Credential username (asks for the password)
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ToolRoot = Split-Path -Parent $PSCommandPath
Remove-Item Env:PSMT_HOME -ErrorAction SilentlyContinue   # only the self-test uses it; a real run always reads its settings from this folder
$files = @($PSCommandPath, (Join-Path $ToolRoot 'lib\Core.ps1'), (Join-Path $ToolRoot 'lib\Engine.ps1'))
$ToolVersion = (Get-Content -Raw -LiteralPath (Join-Path $ToolRoot 'VERSION')).Trim()
$ScriptHash = (($files | ForEach-Object { (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash }) -join '' | ForEach-Object { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($_))).Replace('-', '') })
$HostName = $env:COMPUTERNAME
. (Join-Path $ToolRoot 'lib\Core.ps1')
. (Join-Path $ToolRoot 'lib\Engine.ps1')
Write-Host "PSM health test $ToolVersion  host $HostName  files SHA256 $ScriptHash"
exit (Invoke-Cli @{ Environment = $Environment; Csv = $Csv; Only = ($Only -join ','); NoMail = [bool]$NoMail; DryRun = [bool]$DryRun; Validate = [bool]$Validate; Pause = [bool]$Pause
                    Screenshots = $Screenshots; CleanupPreview = [bool]$CleanupPreview; Trace = [bool]$Trace; Manual = [bool]$Manual; Credential = $(if ($PSBoundParameters.ContainsKey('Credential')) { $Credential } else { $null }); Resume = [bool]$Resume; HeartbeatCheck = [bool]$HeartbeatCheck; TestMail = [bool]$TestMail; Resend = $Resend; Version = [bool]$Version })
