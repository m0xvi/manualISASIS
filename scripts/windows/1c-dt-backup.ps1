<#
.SYNOPSIS
    Выгрузка информационной базы 1С:Предприятие 8 в .dt по расписанию: с предпроверками,
    подавлением диалогов, таймаутом и убийством «зависшего» конфигуратора, проверкой
    результата и ротацией старых файлов.

.DESCRIPTION
    Решает типовые проблемы запуска 1cv8.exe DESIGNER /DumpIB из Планировщика заданий:
      * конфигуратор зависает на невидимом модальном диалоге (нет /DisableStartupDialogs);
      * имя файла строится из %date% и ломается при другой локали/учётке;
      * результат проверяется только по ERRORLEVEL;
      * зависший процесс блокирует следующие запуски задачи;
      * нет ротации и контроля свободного места.

    Коды возврата: 0 - успех, 2 - таймаут (процесс убит), 3 - ошибка предпроверок,
    4 - выгрузка не подтверждена (код возврата 1С, размер файла или журнал).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\1c-dt-backup.ps1 `
        -BasePath "E:\1C_Base\1cv8\Trade" -BackupDir "D:\Backups\1C" -User "backup" `
        -SecretFile "C:\Scripts\1c-backup-secret.txt" -TimeoutMinutes 120 -KeepDays 14

.EXAMPLE
    Клиент-серверная база и код разрешения установки соединения:
    ... -BaseServer "srv1c\trade" -UcCode "BACKUP"

.NOTES
    Пароль пользователя 1С хранится в отдельном файле (первая строка), права на который
    выданы только администраторам, SYSTEM и учётке задачи:

        icacls "C:\Scripts\1c-backup-secret.txt" /inheritance:r
        icacls "C:\Scripts\1c-backup-secret.txt" /grant:r "SYSTEM:(F)" "Administrators:(F)" "DOMAIN\svc-1c-backup:(R)"

    Никогда не пишите пароль 1С в текст скрипта и не кладите его в системы контроля версий.
#>
[CmdletBinding()]
param(
    [string] $BasePath       = 'E:\1C_Base\1cv8\Trade',
    [string] $BaseServer     = '',
    [string] $BaseName       = '',
    [string] $User           = 'backup',
    [string] $SecretFile     = 'C:\Scripts\1c-backup-secret.txt',
    [string] $PlatformDir    = 'C:\Program Files\1cv8',
    [string] $PlatformVer    = '',
    [string] $BackupDir      = 'D:\Backups\1C',
    [string] $LogDir         = '',
    [string] $UcCode         = '',
    [int]    $TimeoutMinutes = 120,
    [int]    $KeepDays       = 14,
    [int]    $MinFreeGB      = 5,
    [switch] $WriteEventLog,
    [switch] $ShowOnly
)

$ErrorActionPreference = 'Stop'

if (-not $LogDir) { $LogDir = Join-Path $BackupDir 'logs' }
$ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
$day = Get-Date -Format 'yyyy-MM-dd'

try { $null = New-Item -ItemType Directory -Force -Path $BackupDir, $LogDir } catch { }

$script:WrapperLog = Join-Path $LogDir ("backup_{0}.log" -f $day)
$script:OneCLog    = Join-Path $LogDir ("1c_{0}.log" -f $ts)

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:WrapperLog -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Fail {
    param([string] $Message, [int] $Code = 3)
    Write-Log $Message 'ERROR'
    if ($WriteEventLog) {
        try { Write-EventLog -LogName Application -Source '1C-DT-Backup' -EntryType Error -EventId 1000 -Message $Message } catch { }
    }
    exit $Code
}

try {

    # --- 0. Источник событий (необязательно, нужны права администратора) ---
    if ($WriteEventLog) {
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('1C-DT-Backup')) {
                New-EventLog -LogName Application -Source '1C-DT-Backup' | Out-Null
            }
        } catch { Write-Log "Не удалось зарегистрировать источник событий: $($_.Exception.Message)" 'WARN' }
    }

    # --- 1. Исполняемый файл платформы: явно указанная версия или самая свежая ---
    if ($PlatformVer) {
        $exe = Join-Path $PlatformDir (Join-Path $PlatformVer 'bin\1cv8.exe')
    } else {
        $latest = Get-ChildItem -LiteralPath $PlatformDir -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                  Sort-Object { [version] $_.Name } -Descending |
                  Select-Object -First 1
        $exe = if ($latest) { Join-Path $latest.FullName 'bin\1cv8.exe' } else { '' }
    }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        Fail "Не найден 1cv8.exe (PlatformDir='$PlatformDir', PlatformVer='$PlatformVer'). Проверьте каталог платформы." 3
    }
    Write-Log "Платформа: $exe"

    # --- 2. Пароль из защищённого файла (в скрипте и в задаче не хранится) ---
    if ($ShowOnly) {
        $Password = '***'
    } else {
        if (-not (Test-Path -LiteralPath $SecretFile)) { Fail "Нет файла с паролем 1С: $SecretFile" 3 }
        $Password = (Get-Content -LiteralPath $SecretFile -TotalCount 1 -ErrorAction Stop).Trim()
        if (-not $Password) { Fail "Файл $SecretFile пуст" 3 }
    }

    # --- 3. Предпроверки ---
    if (-not $BaseServer) {
        if (-not (Test-Path -LiteralPath $BasePath)) { Fail "Каталог файловой базы не найден: $BasePath" 3 }
    }
    try {
        $qualifier = Split-Path -Qualifier $BackupDir
        $freeGb = [math]::Round((Get-PSDrive -Name $qualifier.TrimEnd(':')).Free / 1GB, 1)
        if ($freeGb -lt $MinFreeGB) { Fail "Мало места на диске $qualifier : $freeGb ГБ (требуется $MinFreeGB ГБ)" 3 }
        Write-Log "Свободно на $qualifier : $freeGb ГБ"
    } catch { Write-Log "Не удалось проверить свободное место: $($_.Exception.Message)" 'WARN' }

    # --- 4. Уборка «зависших» конфигураторов от предыдущих выгрузок ---
    #     Убиваем только те процессы 1С, в командной строке которых есть DumpIB:
    #     сеансы пользователей и регламентные задания не затрагиваются.
    try {
        $stale = Get-CimInstance Win32_Process -ErrorAction Stop |
                 Where-Object { $_.Name -like '1cv8*.exe' -and $_.CommandLine -match 'DumpIB' }
        foreach ($p in $stale) {
            Write-Log "Найден незавершённый процесс выгрузки: PID $($p.ProcessId), запущен $($p.CreationDate)" 'WARN'
            if (-not $ShowOnly) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Log "PID $($p.ProcessId) завершён" 'WARN' }
                catch { Write-Log "Не удалось завершить PID $($p.ProcessId): $($_.Exception.Message)" 'WARN' }
            }
        }
    } catch { Write-Log "Проверка процессов недоступна: $($_.Exception.Message)" 'WARN' }

    # --- 5. Имя файла: метка времени не зависит от локали и учётной записи ---
    $name = if ($BaseName) { $BaseName }
            elseif ($BaseServer) { ($BaseServer -split '\\')[-1] }
            else { Split-Path -Leaf $BasePath }
    $dt = Join-Path $BackupDir ("Backup_{0}_{1}.dt" -f $name, $ts)

    # --- 6. Командная строка 1С ---
    $conn = if ($BaseServer) { '/S"{0}"' -f $BaseServer } else { '/F"{0}"' -f $BasePath }
    $uc   = if ($UcCode) { ' /UC"{0}"' -f $UcCode } else { '' }
    $argFmt  = 'DESIGNER {0} /N"{1}" /P"{2}" /DumpIB"{3}" /Out"{4}" -NoTruncate /DisableStartupDialogs /DisableStartupMessages{5}'
    $argLine = $argFmt -f $conn, $User, $Password, $dt, $script:OneCLog, $uc

    $masked  = $argLine -replace [regex]::Escape($Password), '***'
    $cmdLog  = 'Команда: "{0}" {1}' -f $exe, $masked
    Write-Log $cmdLog
    if ($ShowOnly) { Write-Log 'Режим -ShowOnly: запуск не выполняется'; exit 0 }

    # --- 7. Запуск с таймаутом (без Start-Process, чтобы не переэкранировать кавычки) ---
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName          = $exe
    $psi.Arguments         = $argLine
    $psi.WorkingDirectory  = $BackupDir
    $psi.UseShellExecute   = $false
    $psi.CreateNoWindow    = $true
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    Write-Log "Процесс запущен, PID $($proc.Id), лимит $TimeoutMinutes мин"

    if (-not $proc.WaitForExit([int] ($TimeoutMinutes * 60 * 1000))) {
        try { $proc.Kill() } catch { }
        try { $proc.WaitForExit() } catch { }
        $sw.Stop()
        $msg = 'Превышен лимит {0} мин (прошло {1:N1} мин), PID {2} убит. Причины: диалог лицензии, блокировка базы другими сеансами, нехватка места или сети, антивирус.' -f $TimeoutMinutes, $sw.Elapsed.TotalMinutes, $proc.Id
        Fail $msg 2
    }
    $sw.Stop()
    $code = try { $proc.ExitCode } catch { -1 }
    Write-Log ("1С завершилась за {0:N1} мин, код возврата {1}" -f $sw.Elapsed.TotalMinutes, $code)
    try { $proc.Dispose() } catch { }

    # --- 8. Проверка результата: код возврата + файл + журнал 1С ---
    $ok = $true
    if ($code -ne 0) { Write-Log "Код возврата 1С отличен от нуля: $code" 'ERROR'; $ok = $false }

    if (Test-Path -LiteralPath $dt) {
        $size = (Get-Item -LiteralPath $dt).Length
        if ($size -lt 1MB) {
            Write-Log ("Файл создан, но подозрительно мал: {0:N0} байт" -f $size) 'ERROR'; $ok = $false
        } else {
            Write-Log ("Файл: {0} ({1:N1} МБ)" -f $dt, ($size / 1MB))
        }
    } else {
        Write-Log "Файл выгрузки не создан: $dt" 'ERROR'; $ok = $false
    }

    if (Test-Path -LiteralPath $script:OneCLog) {
        $logText = ''
        try { $logText = Get-Content -LiteralPath $script:OneCLog -Raw -Encoding UTF8 } catch { }
        if ($logText -match 'успешно завершена') { Write-Log 'Журнал 1С: выгрузка завершена успешно' }
        if ($logText -match '(?im)^\s*(ошибка|error)') {
            Write-Log 'В журнале 1С есть строки, начинающиеся с «Ошибка»:' 'WARN'
            Get-Content -LiteralPath $script:OneCLog -Encoding UTF8 |
                Where-Object { $_ -match '(?i)^\s*(ошибка|error)' } | Select-Object -First 10 |
                ForEach-Object { Write-Log "  $_" 'WARN' }
            if ($logText -notmatch 'успешно завершена') { $ok = $false }
        }
    } else {
        Write-Log "Журнал 1С не создан: $($script:OneCLog)" 'WARN'
    }

    # --- 9. Ротация ---
    if ($KeepDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$KeepDays)
        Get-ChildItem -LiteralPath $BackupDir -Filter 'Backup_*.dt' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                Write-Log "Ротация: удаляю $($_.Name) ($([math]::Round($_.Length/1MB,1)) МБ, $($_.LastWriteTime))"
                try { Remove-Item -LiteralPath $_.FullName -Force } catch { Write-Log "Не удалось удалить $($_.Name): $($_.Exception.Message)" 'WARN' }
            }
        Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff.AddDays(-$KeepDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # --- 10. Итог ---
    if ($ok) {
        Write-Log 'РЕЗУЛЬТАТ: выгрузка подтверждена'
        if ($WriteEventLog) {
            try { Write-EventLog -LogName Application -Source '1C-DT-Backup' -EntryType Information -EventId 1001 -Message "Выгрузка $dt выполнена" } catch { }
        }
        exit 0
    }
    Fail 'РЕЗУЛЬТАТ: выгрузка не подтверждена (см. журнал выше)' 4

} catch {
    Fail "Непредвиденная ошибка: $($_.Exception.Message)" 3
}
