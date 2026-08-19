@echo off
rem Runs the Pester checks for dev_drive.ps1. Touches no storage, needs no administrator rights.
rem Exit codes: 0 all passed, 1 could not run, 2 Pester missing and install declined,
rem otherwise the number of failures.
setlocal

set "TESTS=%~dp0dev_drive.Tests.ps1"
set "ANSWER="

if not exist "%TESTS%" (
    echo Could not find "%TESTS%".
    exit /b 1
)

rem An if with && binds the operator to the whole condition, not to its body, so the shell
rem is picked with plain blocks instead.
where pwsh >nul 2>&1
if errorlevel 1 (
    where powershell >nul 2>&1
    if errorlevel 1 (
        echo Neither pwsh nor powershell was found on PATH.
        exit /b 1
    )
    set "PS=powershell"
) else (
    set "PS=pwsh"
)

%PS% -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 })) { exit 2 }"
if errorlevel 2 goto no_pester

call :run_tests
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
if /i "%ANSWER%"=="y" goto install
if /i "%ANSWER%"=="yes" goto install
echo Nothing installed.
exit /b 2

:install
%PS% -NoProfile -ExecutionPolicy Bypass -Command "Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser"
if errorlevel 1 (
    echo Installation failed. See https://pester.dev/docs/introduction/installation
    exit /b 1
)

echo.
echo Installed. Running the checks.
echo.
call :run_tests
exit /b %errorlevel%

rem A file that no longer parses fails as a container, not as a test, so all three counts matter.
:run_tests
%PS% -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; $r = Invoke-Pester -Path $env:TESTS -Output Detailed -PassThru; exit ($r.FailedCount + $r.FailedContainersCount + $r.FailedBlocksCount)"
exit /b %errorlevel%
