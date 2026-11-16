# История запросов

Лог обращений: дата → запрос → результат (ссылка на мануал).

| Дата | Запрос | Результат |
|---|---|---|
| 2026-11-16 | Создать репозиторий базы знаний с мануалами и историей запросов. Первая задача: обновить UniFi на Ubuntu Server (бэкап контроллера → обновление контроллера → последовательное обновление точек), сначала проверить ограничения для России. | [UniFi: бэкап и обновление на Ubuntu Server](manuals/network/unifi-ubuntu-backup-and-update.md) |
| 2026-11-16 | Обновление UniFi не удалось: `apt` → `403` на `ui.com`, путь бэкапа `/var/lib/unifi/data/backup/` не найден, `dpkg` не нашёл `unifi_sysvinit_all.deb`, Glenn R. вернул HTML (`!DOCTYPE`). Обновить мануал под реальную ситуацию (Ubuntu 20.04, UniFi 7.x, `/usr/lib/unifi/data`, порт MongoDB 27117, правильный URL Glenn R.). | [UniFi: бэкап и обновление на Ubuntu Server](manuals/network/unifi-ubuntu-backup-and-update.md) — разделы 1–3, 6 |
