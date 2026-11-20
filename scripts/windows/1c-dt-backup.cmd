@echo off
setlocal EnableExtensions

rem Обёртка для Планировщика заданий: вызывает PowerShell-скрипт выгрузки 1С в .dt
rem и возвращает его код возврата (0 - успех, 2 - таймаут, 3 - предпроверки, 4 - результат не подтверждён).
rem В задаче Планировщика заполните также поле "Рабочая папка" (Start in): C:\Scripts

powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\1c-dt-backup.ps1" ^
  -BasePath "E:\1C_Base\1cv8\Trade" ^
  -BackupDir "D:\Backups\1C" ^
  -User "backup" ^
  -SecretFile "C:\Scripts\1c-backup-secret.txt" ^
  -TimeoutMinutes 120 ^
  -KeepDays 14

exit /b %ERRORLEVEL%
