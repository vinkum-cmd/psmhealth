# Signs every .ps1 of the tool with a code-signing certificate from the local store (run as admin, after every change). usage: .\Sign-Scripts.ps1 [-Thumbprint <thumb>]
param([string]$Thumbprint = '')
$cert = if ($Thumbprint) { Get-Item "Cert:\LocalMachine\My\$Thumbprint" } else { Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert | Select-Object -First 1 }
if (-not $cert) { throw 'no code-signing certificate found (create one or pass -Thumbprint)' }
Get-ChildItem -Path $PSScriptRoot -Recurse -Filter *.ps1 | ForEach-Object { $r = Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert; "{0,-12} {1}" -f $r.Status, $_.FullName.Substring($PSScriptRoot.Length + 1) }
