@echo off
rem Arranca BM Mobils en local: base de datos + web, y abre el navegador.
rem Para parar: cierra las dos ventanas que se abren.
set "PATH=%USERPROFILE%\.tools\node-v22.23.4-win-x64;%PATH%"
cd /d "%~dp0"

start "BM Mobils - Base de datos" cmd /k node scripts/local-db.mjs
timeout /t 8 /nobreak >nul
start "BM Mobils - Web" cmd /k npx next dev -p 3000
timeout /t 15 /nobreak >nul
start "" http://localhost:3000
