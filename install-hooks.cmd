@echo off
rem Points git at the tracked .githooks folder so the pre-commit hook there runs
rem before every commit. The hook itself runs the same three checks as
rem .github/workflows/ci.yml: syntax parse, PSScriptAnalyzer, Pester.
rem Exit codes: 0 installed, 1 not a git repository or git config failed.
setlocal

cd /d "%~dp0"

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo Not inside a git repository. Run this from a checkout of dev_drive_creation.
    exit /b 1
)

git config core.hooksPath .githooks
if errorlevel 1 (
    echo Failed to set core.hooksPath.
    exit /b 1
)

echo Hooks installed.
echo.
echo git now runs .githooks\pre-commit before every commit. It parses
echo dev_drive.ps1, runs PSScriptAnalyzer, and runs the Pester suite, then
echo refuses the commit if any of them fails, saying which one and why.
echo.
echo A single commit can still skip it with: git commit --no-verify
echo.
echo To uninstall entirely: git config --unset core.hooksPath
exit /b 0
