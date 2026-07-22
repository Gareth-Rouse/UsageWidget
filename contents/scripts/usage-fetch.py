#!/usr/bin/env python3
"""OMP usage widget fetcher.

Emits a single unified usage JSON object on stdout (see local contract) and
exits 0 even on partial failure: per-provider ``ok``/``error`` carry failures.
"""
import json
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime

SYNTHETIC_URL = "https://api.synthetic.new/v2/quotas"
FIVE_HOUR_RE = re.compile(r"5\s*h|5 hour", re.IGNORECASE)


def iso_to_ms(iso_str):
    """ISO-8601 (e.g. 2026-07-22T14:07:25.303Z) -> ms epoch int."""
    s = iso_str.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return int(datetime.fromisoformat(s).timestamp() * 1000)


def round1(x):
    return round(float(x), 1)


def safe_pct(num, den):
    if not den:
        return 0.0
    return round1(num / den * 100.0)


def relative(resets_at_ms, now_ms):
    diff = resets_at_ms - now_ms
    if diff <= 0:
        return "now"
    secs = diff / 1000.0
    if secs >= 86400:
        return "in {}d".format(round(secs / 86400))
    if secs >= 3600:
        return "in {}h".format(round(secs / 3600))
    if secs >= 60:
        return "in {}m".format(round(secs / 60))
    return "in {}s".format(round(secs))


def provider_err(key, label, default_window_id, error):
    return {
        "key": key,
        "label": label,
        "ok": False,
        "error": str(error),
        "defaultWindowId": default_window_id,
        "windows": [],
    }


def fetch_synthetic(now_ms):
    # bearer key from omp token synthetic
    key = None
    error = None
    try:
        out = subprocess.run(
            ["omp", "token", "synthetic"],
            capture_output=True, text=True, timeout=10,
        )
        key = out.stdout.strip()
        if out.returncode != 0 or not key:
            error = "failed to obtain synthetic token"
    except Exception as exc:  # noqa: BLE001 - surface any subprocess failure
        error = str(exc)
    if error:
        return provider_err("synthetic", "Synthetic", "monthly", error)

    # quotas
    try:
        req = urllib.request.Request(
            SYNTHETIC_URL, headers={"Authorization": "Bearer " + key}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        return provider_err("synthetic", "Synthetic", "monthly", str(exc))

    windows = []

    # monthly <- weeklyTokenLimit credit pool. This is the meaningful monthly
    # subscription burn ($ of the plan's credit allowance used); the separate
    # request counter stays ~0 for token-based usage, so it is not the headline.
    wk = data.get("weeklyTokenLimit", {})
    pct_rem = wk.get("percentRemaining")
    windows.append({
        "id": "monthly",
        "label": "Monthly",
        "usedPercent": round1(100.0 - pct_rem) if pct_rem is not None else 0.0,
        "resetsAt": iso_to_ms(wk["nextRegenAt"]) if wk.get("nextRegenAt") else None,
        "detail": "{} of {} left".format(
            wk.get("remainingCredits", "?"), wk.get("maxCredits", "?")),
    })

    # requests <- subscription request counter (kept for the tooltip)
    sub = data.get("subscription", {})
    m_requests = sub.get("requests", 0)
    m_limit = sub.get("limit", 0)
    windows.append({
        "id": "requests",
        "label": "Requests",
        "usedPercent": safe_pct(m_requests, m_limit),
        "resetsAt": iso_to_ms(sub["renewsAt"]) if sub.get("renewsAt") else None,
        "detail": "{} / {} requests".format(m_requests, m_limit),
    })

    # 5h <- rollingFiveHourLimit
    fh = data.get("rollingFiveHourLimit", {})
    fh_max = fh.get("max", 0)
    fh_remaining = fh.get("remaining", 0)
    windows.append({
        "id": "5h",
        "label": "Rolling 5h",
        "usedPercent": safe_pct(fh_max - fh_remaining, fh_max),
        "resetsAt": iso_to_ms(fh["nextTickAt"]) if fh.get("nextTickAt") else None,
        "detail": "{} / {} left".format(fh_remaining, fh_max),
    })

    return {
        "key": "synthetic",
        "label": "Synthetic",
        "ok": True,
        "error": None,
        "defaultWindowId": "monthly",
        "windows": windows,
    }


def map_usage_windows(report, now_ms):
    """Map an omp-usage report's limits[] to window objects."""
    windows = []
    for lim in report.get("limits", []):
        win = lim.get("window", {}) or {}
        amount = lim.get("amount", {}) or {}
        wid = win.get("id") or lim.get("id") or ""
        wlabel = win.get("label") or lim.get("label") or ""

        used_fraction = amount.get("usedFraction")
        if used_fraction is not None:
            pct = round1(used_fraction * 100.0)
        else:
            pct = safe_pct(amount.get("used", 0), amount.get("limit", 0))

        resets_at = win.get("resetsAt")
        if resets_at is not None:
            detail = "{}% used".format(round(pct))
        else:
            detail = "{} / {} {}".format(
                amount.get("used", 0), amount.get("limit", 0),
                amount.get("unit", ""))

        windows.append({
            "id": wid,
            "label": wlabel,
            "usedPercent": pct,
            "resetsAt": resets_at if resets_at is not None else None,
            "detail": detail,
        })
    return windows


def five_hour_default_window(windows):
    """Primary = the rolling 5h window when present, else the first window.

    OpenAI/Anthropic headline the short-term 5-hour burn; the longer window is
    surfaced as the compact widget's second number.
    """
    for w in windows:
        if FIVE_HOUR_RE.search(w["id"]) or FIVE_HOUR_RE.search(w["label"]):
            return w["id"]
    return windows[0]["id"] if windows else ""


def find_report(reports, name):
    for r in reports:
        if r.get("provider") == name:
            return r
    return None


def main():
    now_ms = int(time.time() * 1000)
    providers = [fetch_synthetic(now_ms)]

    # omp usage --json invoked once for both openai + anthropic
    usage_data = None
    usage_error = None
    try:
        out = subprocess.run(
            ["omp", "usage", "--json"],
            capture_output=True, text=True, timeout=20,
        )
        if out.returncode != 0:
            usage_error = "omp usage exited {}".format(out.returncode)
        else:
            usage_data = json.loads(out.stdout)
    except json.JSONDecodeError as exc:
        usage_error = "omp usage json parse: {}".format(exc)
    except Exception as exc:  # noqa: BLE001
        usage_error = str(exc)

    reports = usage_data.get("reports", []) if usage_data else []

    for key, label, prov_name, default_fn, missing_msg in (
        ("openai", "OpenAI", "openai-codex", five_hour_default_window,
         "no openai-codex usage"),
        ("anthropic", "Anthropic", "anthropic", five_hour_default_window,
         "no anthropic usage"),
    ):
        report = None if usage_error else find_report(reports, prov_name)
        if usage_error or report is None:
            providers.append(provider_err(
                key, label, "",
                usage_error or missing_msg))
        else:
            windows = map_usage_windows(report, now_ms)
            providers.append({
                "key": key,
                "label": label,
                "ok": True,
                "error": None,
                "defaultWindowId": default_fn(windows),
                "windows": windows,
            })

    print(json.dumps({
        "generatedAt": now_ms,
        "ok": True,
        "providers": providers,
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 - never crash the widget
        print(json.dumps({
            "generatedAt": int(time.time() * 1000),
            "ok": False,
            "providers": [],
        }))
        sys.exit(0)
    sys.exit(0)
