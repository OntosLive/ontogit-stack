# Working Snapshot — Alba stable point

## Date
2026-03-01

## Git
- branch: release
- note: created during live stabilization

## Runtime (VPS)
- open-webui image: open-webui-ontogate:db2c5ae10
- nginx proxies alba.ontos.live -> 127.0.0.1:3000
- data universe restored (A+B+C) + runtime image loaded (R)

## Key invariants
- Users/groups/settings present (5 users)
- Models visible via openai-proxy
- Whisper models exist in /app/backend/data cache (hf-cache + faster-whisper)
