@echo off
rem Deploys LFG Suite to the local WoW retail AddOns folder.
rem Run from the repo root (double-click or `deploy` in a shell).
setlocal
set "TARGET=G:\Games\World of Warcraft\_retail_\Interface\AddOns\LFGSuite"
robocopy "%~dp0." "%TARGET%" /E /XD .git .tests /XF .luacheckrc deploy.bat /NFL /NDL /NJH /NP
rem robocopy: 0-7 = success (1 means files copied)
if %ERRORLEVEL% LEQ 7 (
  echo Deployed LFG Suite to %TARGET%
  exit /b 0
) else (
  echo Deploy FAILED (robocopy error %ERRORLEVEL%)
  exit /b 1
)
