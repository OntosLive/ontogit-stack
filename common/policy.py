from __future__ import annotations

from typing import Any


def _to_num(value: Any, fallback: float | None = None) -> float | None:
    if value is None:
        return fallback
    try:
        return float(value)
    except Exception:
        return fallback


def _to_int(value: Any, fallback: int | None = None) -> int | None:
    if value is None:
        return fallback
    try:
        return int(value)
    except Exception:
        return fallback


def load_policy(path: str) -> dict[str, Any] | None:
    """Return normalized policy dict or None when file is missing/invalid."""
    try:
        import os
        if not path or not os.path.isfile(path):
            return None
        import yaml
        with open(path, "r", encoding="utf-8") as f:
            raw = yaml.safe_load(f) or {}
        if not isinstance(raw, dict):
            return None
        if _to_int(raw.get("version")) != 1:
            return None

        roles_raw = raw.get("roles") or {}
        if not isinstance(roles_raw, dict):
            return None

        admin_users = raw.get("admin_users") or []
        if not isinstance(admin_users, list):
            admin_users = []
        admin_users = [str(u).strip() for u in admin_users if str(u).strip()]

        default_role = str(raw.get("default_role") or "basic").strip() or "basic"

        roles: dict[str, dict[str, Any]] = {}
        for role_name, role_cfg in roles_raw.items():
            if not isinstance(role_cfg, dict):
                continue
            daily = role_cfg.get("daily") or {}
            monthly = role_cfg.get("monthly") or {}
            if not isinstance(daily, dict):
                daily = {}
            if not isinstance(monthly, dict):
                monthly = {}
            roles[str(role_name)] = {
                "daily": {
                    "request_limit": _to_int(daily.get("request_limit")),
                    "token_limit": _to_int(daily.get("token_limit")),
                },
                "monthly": {
                    "limit_usd": _to_num(monthly.get("limit_usd"), 0.0),
                    "warn_70": _to_num(monthly.get("warn_70"), 0.7),
                    "warn_90": _to_num(monthly.get("warn_90"), 0.9),
                },
            }

        if not roles:
            return None

        if default_role not in roles:
            default_role = "admin" if "admin" in roles else next(iter(roles.keys()))

        return {
            "version": 1,
            "admin_users": set(admin_users),
            "default_role": default_role,
            "roles": roles,
        }
    except Exception:
        return None


def get_user_role(user_id: str, policy: dict[str, Any] | None, assigned_role: str | None = None) -> str:
    if not policy:
        return (assigned_role or "").strip() or "default"

    uid = (user_id or "").strip()
    roles = policy.get("roles") or {}
    default_role = str(policy.get("default_role") or "basic")
    admin_users = policy.get("admin_users") or set()

    if uid and uid in admin_users and "admin" in roles:
        return "admin"

    role = (assigned_role or "").strip() or default_role
    if role not in roles:
        role = default_role
    return role


def get_daily_limits(role: str, policy: dict[str, Any] | None) -> tuple[int | None, int | None]:
    if not policy:
        return None, None
    cfg = ((policy.get("roles") or {}).get(role) or {}).get("daily") or {}
    req = _to_int(cfg.get("request_limit"))
    tok = _to_int(cfg.get("token_limit"))
    if req is not None and req <= 0:
        req = None
    if tok is not None and tok <= 0:
        tok = None
    return req, tok


def get_monthly_limits(role: str, policy: dict[str, Any] | None) -> tuple[float | None, float, float]:
    if not policy:
        return None, 0.7, 0.9
    cfg = ((policy.get("roles") or {}).get(role) or {}).get("monthly") or {}
    limit = _to_num(cfg.get("limit_usd"), 0.0)
    warn_70 = _to_num(cfg.get("warn_70"), 0.7)
    warn_90 = _to_num(cfg.get("warn_90"), 0.9)
    if limit is not None and limit <= 0:
        limit = None
    return limit, float(warn_70 or 0.7), float(warn_90 or 0.9)
