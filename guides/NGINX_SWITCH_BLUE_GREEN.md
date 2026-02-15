# Nginx Switch Blue/Green (Alba Door)

Canonical one-switch model:

- Use a single `map` to set `$alba_backend`.
- vhost uses `proxy_pass http://$alba_backend`.

Example (snippet):

```nginx
map $host $alba_backend {
    default 127.0.0.1:3000; # blue
}
```

In the vhost:

```nginx
proxy_pass http://$alba_backend;
```

Switching blue/green means changing only the `default` target.

## Warnings and cleanup

### Backups must not live in `sites-enabled`
- Do not leave `*.bak`, `*.old`, or timestamped copies inside `/etc/nginx/sites-enabled/`.
- If you need a backup, store it elsewhere (e.g. `/etc/nginx/sites-available/` or `/var/backups/`).

### Find conflicting `server_name`
- Use `nginx -T` to identify duplicates by line number.

```bash
nginx -T 2>/dev/null | rg -n "server_name\s+alba\.ontos\.live"
```

### Duplicate MIME types
- Duplicate MIME warnings usually come from `include mime.types;` being loaded multiple times.
- Diagnose with line numbers:

```bash
nginx -T 2>/dev/null | rg -n "mime\.types|types \{"
```

If you see the same file included twice, remove one include from the conflicting config.
