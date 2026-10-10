# Unattended Windows Server install for the Skywatch agent. Run as Administrator:
#   $env:SKYWATCH_ENROLLMENT_TOKEN = 'swe_...'
#   .\install.ps1 -Server https://ingest.example.com -Binary .\skywatch-agent.exe
param(
  [Parameter(Mandatory = $true)][string]$Server,
  [string]$Binary = ".\skywatch-agent.exe"
)
$ErrorActionPreference = 'Stop'
if (-not $env:SKYWATCH_ENROLLMENT_TOKEN) { throw "Set SKYWATCH_ENROLLMENT_TOKEN" }
$dir = 'C:\Program Files\Skywatch'
$data = Join-Path $env:ProgramData 'Skywatch'
New-Item -ItemType Directory -Force -Path $dir, $data | Out-Null
Copy-Item $Binary (Join-Path $dir 'skywatch-agent.exe') -Force
# Restrict the state directory to SYSTEM and Administrators.
icacls $data /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
& (Join-Path $dir 'skywatch-agent.exe') enroll --server $Server
if ($LASTEXITCODE -ne 0) { throw "enrollment failed" }
# Runs as LocalSystem (default) because the state directory is restricted to SYSTEM and
# Administrators. The agent performs read-only SCM queries and opens no ports.
New-Service -Name SkywatchAgent -DisplayName 'Skywatch Agent' -StartupType Automatic `
  -BinaryPathName "`"$dir\skywatch-agent.exe`" run" -Description 'Skywatch infrastructure monitoring agent'
sc.exe failure SkywatchAgent reset= 86400 actions= restart/10000/restart/60000/restart/300000 | Out-Null
Start-Service SkywatchAgent
Write-Host 'Skywatch agent installed and running.'
