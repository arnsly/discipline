@echo off
setlocal
cd /d "%~dp0"
git rev-parse --is-inside-work-tree >nul 2>&1 || exit /b 0
git remote get-url origin >nul 2>&1 || exit /b 0
git add data.json data.js >nul 2>&1
git diff --cached --quiet && exit /b 0
git commit -m "time log %DATE% %TIME%" >nul 2>&1
git push >nul 2>&1
exit /b 0