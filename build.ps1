# Сборка OpenCodeAutoContinue.exe
#
#   .\build.ps1
#
# Требует модуль ps2exe (установится автоматически при отсутствии).

param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist\OpenCodeAutoContinue.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host 'Устанавливаю модуль ps2exe...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -Confirm:$false
}

Import-Module ps2exe

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) {
    [void](New-Item -ItemType Directory -Path $outDir -Force)
}

Invoke-PS2EXE `
    -inputFile (Join-Path $PSScriptRoot 'AutoContinue.ps1') `
    -outputFile $OutputPath `
    -noConsole -STA -DPIAware `
    -iconFile (Join-Path $PSScriptRoot 'app.ico') `
    -title 'OpenCode AutoContinue' `
    -description 'Auto-continue OpenCode chats' `
    -product 'OpenCode AutoContinue' `
    -company 'KurumaOfficial' `
    -version '1.2.0.0'

Write-Host "Готово: $OutputPath"
