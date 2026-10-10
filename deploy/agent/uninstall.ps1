# Safe uninstall for Windows. Revoke the agent in the Skywatch UI afterwards.
$ErrorActionPreference = 'SilentlyContinue'
Stop-Service SkywatchAgent
sc.exe delete SkywatchAgent | Out-Null
Remove-Item -Recurse -Force 'C:\Program Files\Skywatch'
Remove-Item -Recurse -Force (Join-Path $env:ProgramData 'Skywatch')
Write-Host 'Skywatch agent removed.'
