@echo off
setlocal

set "SOURCE=%~dp0..\gen1recomp-source"
set "MODS_ROOT=%~dp0.."
if not exist "%MODS_ROOT%\run_gen1recomp_test.bat" (
    echo Could not find the shared Gen1Recomp test launcher:
    echo %MODS_ROOT%\run_gen1recomp_test.bat
    pause
    exit /b 1
)

echo Starting the shared Gen1Recomp mod-selection launcher...
start "Gen1Recomp handheld test" cmd.exe /k call "%MODS_ROOT%\run_gen1recomp_test.bat"

echo Waiting for the game window, then resizing it to 640x480...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0resize_handheld_test.ps1"
if errorlevel 1 (
    echo Could not find a running LÖVE game window within 20 seconds.
    echo Check the Gen1Recomp handheld test window for the actual error.
    pause
    exit /b 1
)

echo Handheld preview window requested at 640x480.
endlocal
