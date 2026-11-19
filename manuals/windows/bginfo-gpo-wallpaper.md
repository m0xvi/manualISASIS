# BGInfo через GPO: корректная смена обоев и разные конфигурации для разных групп

Домен Active Directory, Windows 10/11 и Windows Server 2016+. Разобрано: почему при рассылке BGInfo через GPO «залипает» картинка другого пользователя и отображается некорректно, как разложить политику по пользователям и группам, и какие инструменты убирают проблему со сменой обоев целиком.

## Оглавление

- [0. Почему «залипает» чужая картинка — 5 причин](#0-почему-залипает-чужая-картинка--5-причин)
- [1. Подготовка файлов](#1-подготовка-файлов)
- [2. Настройка .bgi: параметры, которые решают проблему](#2-настройка-bgi-параметры-которые-решают-проблему)
- [3. Развёртывание через GPO](#3-развёртывание-через-gpo)
- [4. Кэш обоев Windows — обязательный шаг](#4-кэш-обоев-windows--обязательный-шаг)
- [5. Разные конфигурации разным пользователям и группам](#5-разные-конфигурации-разным-пользователям-и-группам)
- [6. Проверка и диагностика](#6-проверка-и-диагностика)
- [7. Частые ошибки](#7-частые-ошибки)
- [8. Аналоги: чем заменить BGInfo](#8-аналоги-чем-заменить-bginfo)
- [9. Источники](#9-источники)

---

## 0. Почему «залипает» чужая картинка — 5 причин

BGInfo — это генератор одной картинки: он рисует `.bmp` и прописывает его обоями. Все проблемы со «старой/чужой» картинкой сводятся к тому, **кто** рисовал, **куда** положил файл и **что** Windows держит в кэше.

| № | Причина | Как выглядит | Лечение |
|---|---|---|---|
| 1 | **Общий путь к `.bmp`** (`C:\BGInfo\bginfo.bmp`, сетевая папка, `%ProgramData%`) | У всех пользователей в `HKCU\Control Panel\Desktop\WallPaper` один и тот же путь; кто последним залогинился — того данные и видят остальные | Путь **в профиль пользователя**: `%LocalAppData%\BGInfo\bginfo.bmp`. Документация Microsoft прямо указывает: на терминальных серверах битмап должен лежать в месте, уникальном для каждого пользователя |
| 2 | **Запуск в контексте компьютера** (Computer Configuration → Startup-скрипт) | BGInfo выполняется от `NT AUTHORITY\SYSTEM`: обои попадают в профиль SYSTEM, данные «компьютерные» (без имени пользователя), у пользователей картинка либо не меняется, либо остаётся от прошлой сессии | Запускать **в контексте пользователя** при входе (User Configuration). Для экрана входа — отдельный экземпляр и отдельный `.bgi` (раздел 3) |
| 3 | **Ключ `/all`** в обычной схеме | `/all` перекрашивает обои **всем** залогиненным пользователям данными того сеанса, в котором запустился BGInfo — буквально «чужая картинка» | `/all` нужен только для периодического обновления на общих/терминальных машинах, где BGInfo запускается один раз на компьютер. При запуске от каждого пользователя ключ не использовать |
| 4 | **Кэш обоев Windows** (`TranscodedWallpaper`, `CachedFiles`) | Файл перезаписан, а на экране старая картинка; у пользователя с быстрым переключением/профилями — картинка соседа | Windows транскодирует обои заново **только при смене пути**. Либо чистить кэш (раздел 4), либо перезаписывать и принудительно применять через `SystemParametersInfo` |
| 5 | **Политика «Desktop Wallpaper» / «Force a specific default wallpaper»** | Политика указывает на фиксированный (часто общий) путь и перечитывает его только при смене пути; BGInfo и политика дерутся за одни обои | Не включать ADMX-политику обоев вместе с BGInfo. Корпоративный фон задавать внутри `.bgi` (Background) или через GPP Registry с раскрывающимся путём `%LocalAppData%` |

Дополнительные источники «некорректного отображения»:

- **Текст двоится** (новый поверх старого) — фон в `.bgi` установлен в «Copy existing settings», и при повторном запуске BGInfo берёт за основу собственный предыдущий `.bmp`. Лечится явным фоном (цвет или файл-подложка) в `.bgi`.
- **Чёрные обои / картинка пропала** — путь `%Temp%\bginfo.bmp`: на многопользовательских машинах `%Temp%` раскрывается в `Temp\1`, `Temp\2` по номеру сеанса, и запись в реестре указывает на несуществующий файл. Использовать `%LocalAppData%\…`, не `%Temp%`.
- **Растянуто, не тот размер, один монитор из двух** — настройки Position, «Multiple Monitor Configuration» в `.bgi` и `WallpaperStyle`/`TileWallpaper` в `HKCU\Control Panel\Desktop`.
- **Данные устарели** (сменился IP, подключился VPN) — BGInfo делает снимок один раз. Нужен повторный запуск по расписанию (раздел 3).
- **Пустой или APIPA-адрес** — BGInfo отработал до готовности сети. Включить синхронную обработку политики и задержку запуска (раздел 3).

---

## 1. Подготовка файлов

1. Скачайте BGInfo: `https://download.sysinternals.com/files/BGInfo.zip`. Актуальная версия — **4.34** (15.10.2026), требует **Windows 10 / Server 2016 и выше**; для Windows 7/Server 2008 R2 берите более старую сборку (4.2x). Проверьте доступность с клиента:

```bat
curl -sI https://download.sysinternals.com/files/BGInfo.zip | findstr /i "HTTP content-length"
```

2. Разложите файлы в SYSVOL (оттуда их заберёт GPP Files):

```
\\<домен>\SYSVOL\<домен>\scripts\BGInfo\
├── bginfo64.exe
├── bginfo.exe          ← для 32-разрядных клиентов
├── common.bgi          ← базовая конфигурация
├── staff.bgi           ← вариант для группы «офис»
├── it.bgi              ← вариант для IT (больше полей: NIC, MAC, DNS, шлюз)
├── logon.bgi           ← вариант для экрана входа (запуск от SYSTEM)
├── set-bginfo.cmd
└── clear-wallpaper-cache.cmd
```

3. `set-bginfo.cmd` — обёртка, которую будет вызывать задача (экзешник запускается **локально**, не из SYSVOL: AppLocker/SRP и антивирусы часто запрещают выполнение из UNC, плюс это тормозит вход):

```bat
@echo off
set "BGDIR=C:\ProgramData\BGInfo"
if not exist "%LOCALAPPDATA%\BGInfo" mkdir "%LOCALAPPDATA%\BGInfo"
if "%PROCESSOR_ARCHITECTURE%"=="x86" (set "EXE=%BGDIR%\bginfo.exe") else (set "EXE=%BGDIR%\bginfo64.exe")
"%EXE%" "%BGDIR%\%1" /timer:0 /silent /accepteula /log "%LOCALAPPDATA%\BGInfo\bginfo.log"
```

4. `clear-wallpaper-cache.cmd` — очистка кэша обоев (раздел 4):

```bat
@echo off
del /f /q "%APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper" >nul 2>&1
del /f /q "%APPDATA%\Microsoft\Windows\Themes\CachedFiles\*.*" >nul 2>&1
```

---

## 2. Настройка .bgi: параметры, которые решают проблему

Конфигурацию собирают один раз на тестовой машине (`bginfo64.exe` → GUI → **File | Save As**), дальше её раздают всем. Если `.bgi` не передан в командной строке, BGInfo хранит настройки в `HKCU\Software\Winternals\BGInfo` — у каждого пользователя получится своя версия, поэтому **путь к `.bgi` указывайте всегда явно**.

| Где в GUI | Что выставить | Зачем |
|---|---|---|
| **Bitmap \| Location** | `%LocalAppData%\BGInfo\bginfo.bmp` | Главный пункт. Путь уникален для каждого пользователя → исключает «чужую картинку» (причина 1). Не `%Temp%`, не `C:\BGInfo`, не сетевая папка |
| **Background** | либо явный цвет/файл-подложка (корпоративные обои), либо «Copy existing settings» — но тогда следите, чтобы основой был настоящий фон пользователя, а не сгенерированный `.bmp` | Убирает двоение текста (причина «некорректно отображается») |
| **Position** | «Compensate for Taskbar position», при нескольких мониторах — **Multiple Monitor Configuration** | Текст не уезжает под панель задач и не рисуется только на одном мониторе |
| **Desktops** | «User Desktop». Для варианта `logon.bgi` — дополнительно «Logon Desktop for Console users» (и при необходимости «…for Terminal Services users») | Обычная конфигурация не должна трогать экран входа — это задача отдельного экземпляра от SYSTEM |
| **Fields** | Host Name, IP Address, OS, logged-on user, и т. д.; длинные имена NIC ограничить «Limit Lines to» | Состав надписи; для IT-варианта — больше сетевых полей |
| **Bitmap \| High Color/True Color** | 24-bit | «Match Display» даёт артефакты при смене глубины цвета |

Итоговая командная строка на клиенте:

```bat
"C:\ProgramData\BGInfo\bginfo64.exe" "C:\ProgramData\BGInfo\common.bgi" /timer:0 /silent /accepteula /log "%LOCALAPPDATA%\BGInfo\bginfo.log"
```

Ключи BGInfo 4.34: `/timer:N` (`0` — без диалога, сразу применить), `/silent` (без окон ошибок), `/log <файл>` (писать ошибки в файл — обязательно при запуске по расписанию), `/accepteula`, `/nolicprompt`, `/all` (обои **всем** залогиненным — см. причину 3), `/popup` и `/taskbar` (информация окном/иконкой, обои не трогают — handy для диагностики), `/rtf`, `/I<path>`, `/iq<path>`.

---

## 3. Развёртывание через GPO

### Шаг 0. Общие требования к GPO

- `Computer Configuration → Policies → Administrative Templates → System → Logon → **Always wait for the network at computer startup and logon**` = Enabled (синхронная обработка). Без неё BGInfo стартует до получения IP и рисует `169.254.x.x` или пустоту.
- Доставка файлов — компьютерной частью GPO, запуск — пользовательской (BGInfo нужны данные вошедшего пользователя).

### Шаг 1. Доставка файлов (Computer Configuration)

`Computer Configuration → Preferences → Windows Settings → Files`: скопировать `bginfo64.exe`, `bginfo.exe`, `*.bgi`, `*.cmd` из `\\<домен>\SYSVOL\<домен>\scripts\BGInfo\*` в `C:\ProgramData\BGInfo\`.

- Action: **Update** (или Replace, если меняете версии) — чтобы не перезаписывать файлы при каждом обновлении политики;
- в свойствах элемента снимите «Apply once and do not reapply», если планируете обновлять `.bgi` (иначе изменения не доедут до клиентов);
- права на `C:\ProgramData\BGInfo`: чтение — `Users`, запись — `Administrators`/`SYSTEM`.

### Шаг 2. Запуск в контексте пользователя — рекомендуемый способ (GPP Scheduled Task)

`User Configuration → Preferences → Control Panel Settings → Scheduled Tasks → New → **Immediate Task (At least Windows 7)**`:

- **General**: «Run as» = `%LogonDomain%\%LogonUser%` (GPP подставит текущего пользователя), **Run only when user is logged on** — обязательно, иначе задача уйдёт в контекст SYSTEM;
- **Triggers**: New → «At log on» → **Delay task for: 30 seconds** (оболочка и сеть должны успеть подняться) → Advanced → **Repeat task every 15 minutes**, duration «Indefinitely» — чтобы обновлялись IP/VPN/имя Wi-Fi;
- **Actions**: Start a program → `C:\ProgramData\BGInfo\set-bginfo.cmd`, аргументы `common.bgi`;
- **Conditions**: снять «Start the task only if the computer is on AC power» (иначе ноутбуки от батареи не обновляются);
- **Settings**: «Allow task to be run on demand» — удобно для диагностики.

> Грабли: если имя компьютера совпадает с именем пользователя, GPP иногда создаёт задачу под локальной учёткой `ИМЯПК\user` вместо доменной. Проверяйте на таких машинах отдельно.

### Шаг 2а. Альтернатива — ярлык в Startup

`User Configuration → Preferences → Windows Settings → Shortcuts`: ярлык в `%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup\BGInfo.lnk` с целью `C:\ProgramData\BGInfo\set-bginfo.cmd common.bgi`. Проще всего в настройке, но мелькает консольное окно и нет периодического обновления.

### Шаг 2б. Альтернатива — Logon-скрипт

`User Configuration → Policies → Windows Settings → Scripts → Logon` → `set-bginfo.cmd common.bgi`. Работает, но окно скрипта видно пользователю, а повторное выполнение — только через `gpupdate`/перезаход.

### Шаг 3. Экран входа (если нужен)

Отдельная задача в **Computer Configuration → Preferences → Scheduled Tasks** с триггером «At startup»: `bginfo64.exe C:\ProgramData\BGInfo\logon.bgi /timer:0 /silent /accepteula`, «Run whether user is logged on or not», учётная запись `NT AUTHORITY\SYSTEM`. В `logon.bgi` включён Desktops → «Logon Desktop for Console users», путь к `.bmp` — фиксированный (например `C:\ProgramData\BGInfo\logon.bmp`): здесь это корректно, потому что экран входа один на компьютер. Пользовательские обои эта задача трогать не должна.

---

## 4. Кэш обоев Windows — обязательный шаг

Windows 10/11 не показывает ваш `.bmp` напрямую: она транскодирует его в

```
%APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper
%APPDATA%\Microsoft\Windows\Themes\CachedFiles\CachedImage_<W>_<H>_POS<N>.jpg
```

и **перечитывает источник только тогда, когда меняется путь**. Отсюда «картинка не обновляется» и «висит чужая/старая».

**Решение А (надёжное) — чистить кэш при выходе.** `User Configuration → Policies → Windows Settings → Scripts → Logoff` → `clear-wallpaper-cache.cmd`. К следующему входу кэша нет, Windows транскодирует заново. То же можно сделать через GPP Files (Action = Delete) с таргетингом на те же группы.

**Решение Б — применить принудительно после перезаписи файла.** Если выйти из системы нельзя (RDS-сессия, общий ПК), после запуска BGInfo выполните в контексте пользователя:

```powershell
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Wallpaper {
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
$path = Join-Path $env:LOCALAPPDATA 'BGInfo\bginfo.bmp'
[Wallpaper]::SystemParametersInfo(20, 0, $path, 3) | Out-Null
```

`20` = `SPI_SETDESKWALLPAPER`, `3` = `SPIF_UPDATEINIFILE | SPIF_SENDCHANGE`. Лёгкий вариант без PowerShell — `rundll32.exe user32.dll,UpdatePerUserSystemParameters ,1, True` (срабатывает не на всех сборках 10/11).

**Чего не делать:** не включать вместе с BGInfo политику `User Configuration → Policies → Administrative Templates → Desktop → Desktop Wallpaper` (или `Control Panel → Personalization → Force a specific default wallpaper`). Она пишет `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System\Wallpaper` + `WallpaperStyle` и указывает на фиксированный путь, который перечитывается только при смене пути — в связке с BGInfo это и даёт «залипшую» картинку. Если корпоративный фон обязателен: задайте его внутри `.bgi` (Background) либо выставьте `HKCU\Control Panel\Desktop` (`WallPaper`, `WallpaperStyle` = `10` Fill, `TileWallpaper` = `0`) через GPP Registry с раскрывающимся `%LocalAppData%`-путём.

---

## 5. Разные конфигурации разным пользователям и группам

Задача: «пользователю X на всех его устройствах — одна конфигурация, группе Y — другая».

### 5.1. Базовое правило размещения

Пользовательские настройки идут **за пользователем**, поэтому GPO линкуется на OU, где лежат **объекты пользователей** (или на домен, если нужно всем). Loopback при этом не нужен. Компьютерные настройки (доставка файлов) — на OU с компьютерами.

```
DC
├── OU=Computers   ← GPO «BGInfo-Files» (Computer Configuration: GPP Files, «Always wait for the network…»)
└── OU=Users
    ├── OU=Staff   ← GPO «BGInfo-Staff» (User Configuration: задача со staff.bgi)
    └── OU=IT      ← GPO «BGInfo-IT»   (User Configuration: задача с it.bgi)
```

### 5.2. Security Filtering и грабли MS16-072 (KB3163622)

Чтобы GPO применялся только к нужным людям:

1. В GPMC откройте GPO → вкладка **Delegation** → кнопка **Advanced** → найдите `Authenticated Users` → оставьте **только Read** (снимите «Apply group policy»).
2. На вкладке **Scope → Security Filtering** удалите `Authenticated Users` и добавьте группу, например `GG-BGInfo-Staff`.

**Критично:** после MS16-072 пользовательские политики читаются **в контексте компьютера**, поэтому у `Authenticated Users` (или у `Domain Computers`) обязательно должно остаться право **Read** на GPO. Если его убрать совсем — политика молча перестанет применяться ни к кому. Право «Apply group policy» этим группам при этом давать **не нужно** (иначе таргетинг сломается).

Проверка всех GPO домена на соответствие:

```powershell
Get-GPO -All | ForEach-Object {
  $p = Get-GPPermissions -Guid $_.Id -All
  $ok = $p | Where-Object { $_.Trustee.Name -in 'Authenticated Users','Domain Computers' -and $_.Permission -in 'GpoRead','GpoApply' }
  if (-not $ok) { "НЕТ READ: $($_.DisplayName)" }
}
```

Для одного конкретного пользователя механика та же: добавьте в Security Filtering учётку пользователя (или, что лучше, персональную группу `GG-BGInfo-UserX`) — иначе при каждом изменении придётся править GPO.

### 5.3. Item-Level Targeting — предпочтительный способ

Вместо нескольких GPO удобнее один GPO и несколько элементов GPP, у каждого — свой таргетинг: элемент → вкладка **Common** → **Item Level Targeting** → Edit.

| Условие | Пример |
|---|---|
| **Security Group** | `GG-BGInfo-IT` → задача с `it.bgi` |
| **User** | конкретный пользователь → задача с персональным `.bgi` |
| **Security Group + Not** | «все из `GG-BGInfo-Staff`, кроме `GG-BGInfo-Excluded`» |
| **Operating System** | только Windows 11 → другой набор полей |
| **OU / Site / IP Address Range** | филиал или подсеть → свой вариант |

Правила вычисления: условия внутри одного элемента соединяются логическим **AND**, порядок проверяется сверху вниз (стрелками), `Not` инвертирует результат условия. Так «одному пользователю — своя конфигурация на всех устройствах» делается одной строкой таргетинга `User = X`, а «другой группе — другая» строкой `Security Group = GG-…`.

### 5.4. Если два GPO всё-таки пересеклись

Приоритет определяется порядком линков в GPMC (**Link Order: 1 = самый приоритетный**), затем `Enforced` (преодолевает блокирование наследования) и `Block Policy Inheritance` на OU. Для GPP-элементов одного типа последний применившийся элемент перезаписывает предыдущий — поэтому пересечения лучше не допускать таргетингом, а не порядком линков.

### 5.5. Когда нужен loopback

`Computer Configuration → Policies → Administrative Templates → System → Group Policy → **Configure user Group Policy loopback processing mode**` (включается в GPO, привязанном к OU **компьютеров**):

- **Replace** — пользовательские настройки берутся только из GPO, привязанных к OU компьютера;
- **Merge** — пользовательские настройки суммируются, при конфликте побеждают GPO компьютера.

Нужен, когда конфигурацию определяет **машина**, а не человек: киоски, учебные классы, терминальные фермы, тонкие клиенты. Для требования «пользователю X на всех устройствах одна конфигурация» loopback **не включать** — с ним настройки поедут за компьютером и перестанут следовать за пользователем.

### 5.6. WMI-фильтры

Только если без них нельзя (проверка версии ОС, наличие ПО): WMI-фильтр применяется ко всему GPO и дорог по CPU на каждом обновлении политики. Для «кто входит в группу» используйте Security Filtering или Item-Level Targeting.

---

## 6. Проверка и диагностика

```bat
gpresult /h "%USERPROFILE%\Desktop\gpresult.html"
gpresult /r /scope user
reg query "HKCU\Control Panel\Desktop" /v WallPaper
reg query "HKCU\Control Panel\Desktop" /v WallpaperStyle
dir "%LOCALAPPDATA%\BGInfo"
type "%LOCALAPPDATA%\BGInfo\bginfo.log"
schtasks /query /tn "BGInfo" /v /fo LIST
```

- **Event Viewer**: `Applications and Services Logs → Microsoft → Windows → GroupPolicy/Operational` (применение пользовательских политик) и `TaskScheduler → Operational` (запуск задачи; историю нужно включить: «Enable All Tasks History»).
- **Проверка контекста**: в задаче должно быть «Run only when user is logged on» и учётка `%LogonDomain%\%LogonUser%`. Быстрый тест — заменить BGInfo на `cmd /c whoami > %LOCALAPPDATA%\BGInfo\who.txt` и посмотреть, кто реально запустился.
- **Тест на «чужую картинку»** — главный: залогиньте **двух разных пользователей на одной машине** (быстрое переключение или две RDS-сессии) и сравните надписи и пути:

```bat
reg query "HKCU\Control Panel\Desktop" /v WallPaper
```

Пути должны отличаться профилем (`…\Users\user1\AppData\Local\BGInfo\bginfo.bmp` и `…\user2\…`), а данные на картинке — совпадать со «своим» пользователем.
- **Диагностика без обоев**: `bginfo64.exe common.bgi /popup` или `/taskbar` — информация покажется окном, файлы обоев не трогаются. Если в окне данные верные, а на обоях нет — проблема не в BGInfo, а в кэше/политике обоев (раздел 4).

---

## 7. Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Видны имя/IP другого пользователя | Общий путь `.bmp` или `/all` | `%LocalAppData%\BGInfo\bginfo.bmp`, `/all` убрать (раздел 0, причины 1 и 3) |
| Картинка не обновляется после правки `.bgi` | Кэш `TranscodedWallpaper`/`CachedFiles` | Logoff-скрипт `clear-wallpaper-cache.cmd` или `SystemParametersInfo` (раздел 4) |
| Обои чёрные / пропали | `%Temp%` на многопользовательской машине (`Temp\1`, `Temp\2`), недоступный путь, нет прав | Путь в `%LocalAppData%`, файлы локально в `C:\ProgramData\BGInfo`, чтение для Users |
| Текст наложен поверх старого текста | Background = «Copy existing settings» + повторный запуск по своему `.bmp` | Явный фон в `.bgi` (цвет или файл-подложка) |
| В надписи `169.254.x.x` или пусто | BGInfo отработал до готовности сети | «Always wait for the network at computer startup and logon» + задержка 30–60 с в триггере |
| Данные не обновляются после смены IP/VPN | BGInfo — снимок, сам не перезапускается | Повтор задачи каждые 10–15 минут (раздел 3, шаг 2) |
| Политика не применяется ни к кому после точечного Security Filtering | Убран `Authenticated Users` целиком → грабли MS16-072 | Вернуть `Authenticated Users` или `Domain Computers` с правом **Read** (без Apply) |
| Задача создана, но не запускается у обычных пользователей | «Run whether user is logged on or not» / учётка группы вместо `%LogonDomain%\%LogonUser%` | «Run only when user is logged on», Run as = `%LogonDomain%\%LogonUser%` |
| Экзешник не запускается из SYSVOL | AppLocker/SRP/антивирус блокируют выполнение по UNC | Копировать файлы локально через GPP Files и запускать из `C:\ProgramData\BGInfo` |
| На ноутбуках не обновляется | Условие «только при питании от сети» | Снять условие в настройках задачи |
| Информация нужна на экране входа, а её нет | Пользовательская задача не выполняется до входа | Отдельная компьютерная задача от SYSTEM с `logon.bgi` (раздел 3, шаг 3) |

---

## 8. Аналоги: чем заменить BGInfo

Если цель — «информация на рабочем столе», а борьба идёт именно за смену картинки, проще всего **не менять обои вообще**: оверлейные инструменты рисуют поверх/под иконками в своём процессе, у каждого сеанса свой экземпляр, кэш обоев и чужие профили не участвуют.

| Инструмент | Принцип | Живые метрики | Экран входа | Лицензия | Комментарий |
|---|---|---|---|---|---|
| **BGInfo 4.34** (Sysinternals) | Перезаписывает обои `.bmp` | Нет, снимок при запуске | Да (отдельный экземпляр от SYSTEM) | Freeware, Microsoft | Штамп виден на скриншоте и на экране блокировки; требует дисциплины по путям и кэшу (весь этот мануал) |
| **Desktop Info 3.23.0** (Glenn Delahoy, 08.2026) | Резидентный оверлей «прикреплённый к рабочему столу», под иконками; есть режимы обычного окна, скринсейвера и **службы Windows** | Да, реальное время | Да, через режим службы | Freeware, портативный (zip) или installer | Наиболее близкая замена: `.ini`-конфигурация, свои WMI/PDH-запросы, вызов внешних команд и PowerShell, мульти-монитор, масштабирование, логирование в файл и Event Log, Unicode. Win7+. Сайт: `https://www.glenn.delahoy.com/desktopinfo/` |
| **Rainmeter** | Скины-виджеты поверх обоев | Да | Нет | Open Source (GPL-2.0) | Максимальная гибкость и «красиво», но профиль скина надо готовить и раскладывать в `%APPDATA%\Rainmeter`; тяжелее по ресурсам |
| **PowerShell + System.Drawing** (в т. ч. готовые обёртки типа PowerBGInfo) | Свой рендер текста поверх корпоративных обоев, установка через `SystemParametersInfo` | По коду | Можно | Свой код | Полный контроль: любые данные из AD/WMI/инвентаризации, свой шаблон; но код надо сопровождать |
| **XComms ProView** и коммерческие EUEM/клиент-менеджеры (Quest Desktop Authority, Ivanti EPM, ManageEngine Endpoint Central) | Централизованное управление рабочим столом и данными | Зависит от продукта | Зависит | Платно | Без скриптов и самописных GPO; возможности по обоям и составу полей уточняйте под свою версию |
| WPInfo, BGINFO4X | Клоны/надстройки над идеей BGInfo | — | — | Open Source | Проекты заброшены (discontinued) — не рекомендую |

**Рекомендация:**

- Нужен именно **штамп на обоях** (виден на скриншоте, на экране блокировки и у пользователя без прав на установку софта) → BGInfo по схеме разделов 1–4.
- Нужна **живая информация** и важна беспроблемная смена картинки → **Desktop Info**: тот же деплой через GPP Files + Scheduled Task в контексте пользователя, но обои не трогаются, поэтому причины 1, 3, 4 и 5 из раздела 0 исчезают как класс. Конфигурация — один `.ini` на группу, таргетинг — тот же (раздел 5).
- Нужно «красиво» и есть готовность сопровождать скины → Rainmeter.

---

## 9. Источники

- Microsoft Learn, Sysinternals **BgInfo v4.34** (15.10.2026): ключи командной строки, «Bitmap \| Location … On Terminal Services servers the bitmap should be placed in a location that is unique to each user», Desktops/Logon Desktop, `/all`.
- Microsoft / KB3163622 и TechCommunity «Deploying Group Policy Security Update MS16-072»: пользовательские политики читаются в контексте компьютера, `Authenticated Users`/`Domain Computers` должны иметь **Read**.
- Практика по кэшу обоев: `%APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper` и `CachedFiles` (EduGeek, Spiceworks, r/sysadmin) — перечитывание только при смене пути, лечение удалением кэша в logoff-скрипте.
- Грабли `%Temp%` → `Temp\1/2` на многопользовательских машинах и `%LocalAppData%\Temp` как замена (r/sysadmin).
- GPP Scheduled Task с `%LogonDomain%\%LogonUser%`, триггер «At log on» и «Delay task for» (практика Citrix/RDS-развёртываний); кейс с совпадением имени ПК и пользователя (Experts Exchange).
- Сравнение инструментов: netthinks «System Information for Windows Server» (BGInfo / Desktop Info / Rainmeter / PowerBGInfo / XComms ProView), AlternativeTo; официальный сайт Desktop Info.

---

*Проверено по документации и типовым развёртываниям: ноябрь 2026.*
