# Daily Beta Report

This ritual summarizes telemetry for the last N days. It does **not** log any prompt/response text.

## Run
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/report_daily.sh
DAYS=14 ./scripts/report_daily.sh
```

Artifacts are stored in `ops/state/<ts>_report_daily/`:
- `raw.json`
- `table.txt`
- `how_to_repeat.txt`

## Metrics meaning
- `date`: UTC day bucket (`day_ts` from usage-writer).
- `dau`: daily active users (unique `user_id`).
- `requests`: total requests recorded.
- `tokens`: total tokens (from `usage.total_tokens`; falls back to `tokens_in + tokens_out`).
- `usd_est`: approximate USD based on tokens (rough estimate).
- `errors`: count of rows where `http_status >= 400` or `error_type` is set.

## Reading usd_est vs tokens
- `usd_est` is a rough cost estimate derived from token counts.
- Use tokens to compare usage volume; use `usd_est` only for rough cost trends.

## If errors are rising
1) Check `openai-proxy` logs: `docker logs ontogit-stack-openai-proxy-1`.
2) Check upstream connectivity and rate limits.
3) Verify `ONTOGIT_TELEMETRY=1` is set in the running environment.
