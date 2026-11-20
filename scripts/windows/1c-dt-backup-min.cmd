@echo off
setlocal EnableExtensions

rem ============================================================
rem  Minimal fixed version of a 1C .dt backup script (pure cmd).
rem  Messages are intentionally ASCII: a .cmd saved as UTF-8 shows
rem  Cyrillic as garbage in the OEM codepage. If you need Russian
rem  text, save the file as CP866 or put "chcp 65001 >nul" first.
rem
rem  Fixes vs. the typical broken variant:
rem   1. /DisableStartupDialogs + /DisableStartupMessages - the Designer
rem      can no longer hang on an invisible modal dialog (the main reason
rem      for zombie 1cv8.exe processes under Task Scheduler);
rem   2. timestamp from PowerShell instead of %date% - file name does not
rem      depend on locale or on the account running the task;
rem   3. unique file name per run (no overwrite, no file lock conflicts);
rem   4. pre-flight checks: platform exe, base folder, password;
rem   5. stale DumpIB processes are killed before start (user sessions
rem      are not touched - the filter matches DumpIB in the command line);
rem   6. wrapper log and 1C /Out log are separate files (cmd writes OEM,
rem      1C writes UTF-8; one shared file turns into garbage);
rem   7. result is verified by exit code AND by the .dt file size;
rem   8. retention via forfiles.
rem ============================================================

rem === Settings ===
set "EXE_1C=C:\Program Files\1cv8\8.3.22.1709\bin\1cv8.exe"
set "DB_PATH=E:\1C_Base\1cv8\Trade"
set "DB_USER=backup"
set "BASE_NAME=Trade"
set "BACKUP_DIR=D:\Backups\1C"
set "LOG_DIR=%BACKUP_DIR%\logs"
set "SECRET_FILE=C:\Scripts\1c-backup-secret.txt"
set "KEEP_DAYS=14"
set "MIN_SIZE=1048576"

rem === Locale-independent timestamp ===
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"`) do set "TS=%%i"
if not defined TS (
    echo FATAL: cannot get timestamp from PowerShell
    exit /b 3
)

rem === 1C password from a file with restricted ACL (first line) ===
set "DB_PASS="
if exist "%SECRET_FILE%" set /p DB_PASS=<"%SECRET_FILE%"

set "DT=%BACKUP_DIR%\Backup_%BASE_NAME%_%TS%.dt"
set "LOG=%LOG_DIR%\wrapper.log"
set "OUT1C=%LOG_DIR%\1c_%TS%.log"

if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

echo %DATE% %TIME% START dump to %DT% >> "%LOG%"

rem === Pre-flight checks ===
if not exist "%EXE_1C%" (
    echo %DATE% %TIME% ERROR platform exe not found: %EXE_1C% >> "%LOG%"
    exit /b 3
)
if not exist "%DB_PATH%" (
    echo %DATE% %TIME% ERROR infobase folder not found: %DB_PATH% >> "%LOG%"
    exit /b 3
)
if not defined DB_PASS (
    echo %DATE% %TIME% ERROR empty password, check %SECRET_FILE% >> "%LOG%"
    exit /b 3
)

rem === Kill stale Designer processes left by previous dumps (DumpIB only) ===
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -like '1cv8*.exe' -and $_.CommandLine -like '*DumpIB*' } | ForEach-Object { Write-Host ('killing stale PID ' + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force }" >> "%LOG%" 2>&1

rem === Dump ===
"%EXE_1C%" DESIGNER /F"%DB_PATH%" /N"%DB_USER%" /P"%DB_PASS%" /DumpIB"%DT%" /Out"%OUT1C%" -NoTruncate /DisableStartupDialogs /DisableStartupMessages
set "RC=%ERRORLEVEL%"

rem === Verify result ===
set "OK=1"
if not "%RC%"=="0" set "OK=0"
if not exist "%DT%" (
    set "OK=0"
) else (
    for %%F in ("%DT%") do if %%~zF LSS %MIN_SIZE% set "OK=0"
)

rem === Retention ===
forfiles -p "%BACKUP_DIR%" -m "Backup_*.dt" -d -%KEEP_DAYS% -c "cmd /c del @path" >nul 2>&1

if "%OK%"=="1" (
    echo %DATE% %TIME% SUCCESS rc=%RC% file=%DT% >> "%LOG%"
    echo --------------------------------------- >> "%LOG%"
    exit /b 0
)
echo %DATE% %TIME% FAILED rc=%RC% file=%DT% see %OUT1C% >> "%LOG%"
echo --------------------------------------- >> "%LOG%"
if "%RC%"=="0" exit /b 4
exit /b %RC%
