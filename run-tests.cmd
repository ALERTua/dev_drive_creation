@echo off
rem Runs the Pester checks for dev_drive.ps1. Touches no storage, needs no administrator rights.
rem Exits with the number of failed tests, so it can be used from a pipeline.
setlocal

set "TESTS=%~dp0dev_drive.Tests.ps1"

if not exist "%TESTS%" (
    echo Could not find "%TESTS%".
    exit /b 1
)

where pwsh >nul 2>&1
if errorlevel 1 (set "PS=powershell") else (set "PS=pwsh")

%PS% -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 })) { exit 2 }"
if errorlevel 2 goto no_pester

%PS% -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; $result = Invoke-Pester -Path '%TESTS%' -Output Detailed -PassThru; exit $result.FailedCount"
exit /b %errorlevel%

:no_pester
echo.
echo Pester 5 or newer is not installed, so the checks cannot run.
echo.
echo Windows ships Pester 3.4, which is too old for this suite. The current
echo version comes from the PowerShell Gallery:
echo.
echo     Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser
echo.
echo -SkipPublisherCheck is needed because the copy shipped with Windows is
echo signed by Microsoft and the gallery build is signed by the Pester team.
echo -Scope CurrentUser installs into your profile, not into the system.
echo.
echo Homepage: https://pester.dev/
echo.
set /p ANSWER=Install it now? [y/N] 
if /i not "%ANSWER%"=="y" (
    echo Nothing installed.
    exit /b 2
)

%PS% -NoProfile -ExecutionPolicy Bypass -Command "Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser"
if errorlevel 1 (
    echo Installation failed. See https://pester.dev/docs/introduction/installation
    exit /b 1
)

echo.
echo Installed. Running the checks.
echo.
%PS% -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; $result = Invoke-Pester -Path '%TESTS%' -Output Detailed -PassThru; exit $result.FailedCount"
exit /b %errorlevel%
