# Universe Clone Runbook (LOCAL → VPS) — ONE TRUE FILE

Цель: перенести **всю реальность 1:1** (UI + базы + реколлы/память + учёт) с локалки на VPS.
Не перенос “образа”, а перенос **вселенной**.

## Определения
**Universe A (OpenWebUI data)** = всё, что смонтировано в `/app/backend/data`
- webui.db (+ wal/shm)
- users, groups, settings, chats, presets, providers
- uploads/
- .webui_secret_key (обязателен)

**Universe B (OntoGit user/usage)** = usage.db и всё, что рядом
- обычно `/home/ontoslive/ontos_data/ontogit-user`

**Universe C (Qdrant memory)** = qdrant persistent data (volume/host dir)

---

## 0) Принцип безопасности
Всегда делаем бэкап **до** замены на VPS.

---

## 1) Локалка: снять SOURCE PATH для Universe A
Команда (источник истины):
```bash
docker inspect ontogit-stack-open-webui-1 --format '{{range .Mounts}}{{if eq .Destination "/app/backend/data"}}{{.Source}}{{end}}{{end}}'
