param(
    [Parameter(Mandatory = $true)]
    [string]$Source
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $Source 'yellow\data\generated\maps.lua'))) {
    Write-Host 'error: generated data missing at yellow\data\generated\maps.lua' -ForegroundColor Red
    Write-Host 'Run scripts\setup.ps1 in the gen1recomp source checkout first.'
    exit 1
}

function Find-Love {
    foreach ($name in 'lovec', 'love') {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($directory in @(
        "$env:ProgramFiles\LOVE",
        "${env:ProgramFiles(x86)}\LOVE",
        "$env:LOCALAPPDATA\Programs\LOVE"
    )) {
        foreach ($name in 'lovec.exe', 'love.exe') {
            $path = Join-Path $directory $name
            if ($directory -and (Test-Path $path)) { return $path }
        }
    }
    return $null
}

$love = Find-Love
if (-not $love) {
    Write-Host 'error: LÖVE was not found.' -ForegroundColor Red
    Write-Host 'Install LÖVE or run scripts\setup.ps1 first.'
    exit 1
}

Write-Host "Starting LÖVE from $Source"
& $love $Source
exit $LASTEXITCODE
