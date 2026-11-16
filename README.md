# manualISASIS — База знаний IT

Краткие практические мануалы: открыть → выполнить → готово. Без воды.

## Как пользоваться

1. Найдите тему в оглавлении ниже.
2. Откройте мануал — в начале каждого есть своё оглавление.
3. Выполняйте шаги по порядку.

## Оглавление

### Сеть / Wi-Fi

| Мануал | Что внутри |
|---|---|
| [UniFi: бэкап и обновление на Ubuntu Server](manuals/network/unifi-ubuntu-backup-and-update.md) | Бэкап контроллера, обновление контроллера на Ubuntu, последовательное обновление точек доступа, ограничения для РФ |

### Серверы / Linux

_Пока пусто — добавляйте новые мануалы в `manuals/server/`._

### Windows / Рабочие станции

_Пока пусто — добавляйте новые мануалы в `manuals/windows/`._

### Прочее

_Пока пусто._

## Структура репозитория

```
manualISASIS/
├── README.md              ← это оглавление
├── HISTORY.md             ← история запросов
├── manuals/               ← мануалы по категориям
│   └── network/           ← сеть и Wi-Fi
├── assets/                ← скриншоты и схемы к мануалам
│   └── network/
├── references/            ← справочники и входные данные workflow
└── .github/workflows/     ← зеркала файлов Ubiquiti через GitHub Actions
```

## Зеркала файлов Ubiquiti (GitHub Actions)

Серверы Ubiquiti отдают российским IP `403`/`451`, поэтому нужные файлы скачивают раннеры GitHub (IP вне РФ), проверяют sha256 и публикуют в релизах репозитория. Сервер забирает их обычным `curl -fL` без VPN.

| Workflow | Что делает | Релиз | Входные данные |
|---|---|---|---|
| `fetch-unifi-deb.yml` | зеркалит `.deb` UniFi Network Application из архива `api.glennr.nl` | [`unifi-8.5.6`](https://github.com/m0xvi/manualISASIS/releases/tag/unifi-8.5.6) | `UNIFI_VERSION`, `EXPECTED_SHA256` в файле workflow |
| `fetch-unifi-ap-firmware.yml` | зеркалит прошивки устройств (`.bin`) с `fw-download.ubnt.com` | [`unifi-ap-firmware`](https://github.com/m0xvi/manualISASIS/releases/tag/unifi-ap-firmware) | [`references/ap-firmware-wanted.txt`](references/ap-firmware-wanted.txt) — коды платформ, по одному на строку |

Справочник кодов платформ и последних release-версий (≈625 строк, собирается автоматически job `catalog`): [`references/unifi-firmware-platform-codes.md`](references/unifi-firmware-platform-codes.md). Порядок действий описан в мануале: раздел 3, Способ 2 (контроллер) и раздел 4.1 (точки).

> Ассеты релизов публичные. После использования зеркало удаляют: `gh release delete <tag> --repo m0xvi/manualISASIS --yes`.

## Правила для новых мануалов

- Язык — русский, коротко, по делу.
- Каждый мануал: заголовок → оглавление → шаги → проверка результата.
- Скриншоты класть в `assets/<категория>/<тема>/`, в тексте ссылаться относительным путём.
- После добавления мануала: дописать строку в [HISTORY.md](HISTORY.md) и в оглавление выше.
