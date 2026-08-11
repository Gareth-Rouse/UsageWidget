#!/usr/bin/env python3
"""OMP usage widget fetcher.

Emits a single unified usage JSON object on stdout (see local contract) and
exits 0 even on partial failure: per-provider ``ok``/``error`` carry failures.

Every provider reported by ``omp usage --json`` is emitted; the widget itself
decides which providers and which window to show. ``synthetic`` is replaced by
a richer direct quotas fetch (it exposes the monthly credit pool, which the
omp report does not).
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

# Pretty names / compact panel codes for the providers we know about. Unknown
# providers fall back to a derived label and first-letter code.
PROVIDER_LABELS = {
    "synthetic": "Synthetic",
    "openai-codex": "OpenAI",
    "anthropic": "Anthropic",
    "google-antigravity": "Antigravity",
    "github-copilot": "Copilot",
}
PROVIDER_CODES = {
    "synthetic": "S",
    "openai-codex": "O",
    "anthropic": "A",
    "google-antigravity": "G",
    "github-copilot": "C",
}



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


def provider_label(key):
    return PROVIDER_LABELS.get(key) or key.replace("-", " ").title()


def provider_code(key, taken):
    """Single-letter panel code, widened on collision (S, SY, SYN…)."""
    code = PROVIDER_CODES.get(key)
    if code and code not in taken:
        return code
    stem = re.sub(r"[^a-z]", "", key.lower()) or "?"
    for n in range(1, len(stem) + 1):
        cand = stem[:n].upper()
        if cand not in taken:
            return cand
    return stem.upper()


def provider_err(key, label, error):
    return {
        "key": key,
        "label": label,
        "code": "",
        "ok": False,
        "error": str(error),
        "defaultWindowId": "",
        "windows": [],
    }


def fetch_synthetic():
    """Synthetic quotas straight from the API (richer than the omp report)."""
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
        return provider_err("synthetic", "Synthetic", error)

    try:
        req = urllib.request.Request(
            SYNTHETIC_URL, headers={"Authorization": "Bearer " + key}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        return provider_err("synthetic", "Synthetic", str(exc))

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

    # requests <- subscription request counter
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
        "code": "",
        "ok": True,
        "error": None,
        "defaultWindowId": "monthly",
        "windows": windows,
    }


def map_usage_windows(report):
    """Map an omp-usage report's limits[] to window objects.

    The window id is the *limit* id, because several limits of one provider can
    share a window id (anthropic has two distinct 7d limits). Labels prefer the
    limit label and only fall back to appending the window label when two
    limits of the same provider would otherwise be indistinguishable.
    """
    limits = report.get("limits", []) or []
    label_counts = {}
    for lim in limits:
        base = lim.get("label") or (lim.get("window", {}) or {}).get("label") or ""
        label_counts[base] = label_counts.get(base, 0) + 1

    windows = []
    seen_ids = set()
    for idx, lim in enumerate(limits):
        win = lim.get("window", {}) or {}
        amount = lim.get("amount", {}) or {}

        wid = lim.get("id") or win.get("id") or "w{}".format(idx)
        while wid in seen_ids:
            wid = "{}#{}".format(wid, idx)
        seen_ids.add(wid)

        base = lim.get("label") or win.get("label") or wid
        wlabel = base
        if label_counts.get(base, 0) > 1 and win.get("label"):
            wlabel = "{} · {}".format(base, win.get("label"))

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


def pick_default_window(windows):
    """Primary = the rolling 5h window when present, else the first window.

    OpenAI/Anthropic headline the short-term 5-hour burn; longer windows are
    still selectable from the widget's configuration page. Runs on the sorted
    window list so the pick does not drift between refreshes.
    """
    for w in windows:
        if FIVE_HOUR_RE.search(w["id"]) or FIVE_HOUR_RE.search(w["label"]):
            return w["id"]
    return windows[0]["id"] if windows else ""




def main():
    now_ms = int(time.time() * 1000)
    providers = [fetch_synthetic()]

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

    if usage_error:
        # Keep the two staples visible with their error, so the panel explains
        # itself instead of silently dropping providers.
        for key in ("openai-codex", "anthropic"):
            providers.append(provider_err(key, provider_label(key), usage_error))
    else:
        for report in reports:
            key = report.get("provider") or ""
            if not key or key == "synthetic":
                continue  # synthetic comes from the direct quotas fetch above
            if report.get("error"):
                providers.append(
                    provider_err(key, provider_label(key), report["error"]))
                continue
            windows = map_usage_windows(report)
            providers.append({
                "key": key,
                "label": provider_label(key),
                "code": "",
                "ok": True,
                "error": None,
                "defaultWindowId": "",
                "windows": windows,
            })

    # omp does not guarantee report/limit ordering; sort so the panel segments
    # and the config rows keep a fixed position between refreshes. Synthetic
    # stays first because it is the local, always-present provider.
    head = providers[:1]
    tail = sorted(providers[1:], key=lambda p: p["key"])
    providers = head + tail
    for prov in providers:
        prov["windows"].sort(key=lambda w: w["id"])
        if not prov["defaultWindowId"]:
            prov["defaultWindowId"] = pick_default_window(prov["windows"])

    taken = set()
    for prov in providers:
        prov["code"] = provider_code(prov["key"], taken)
        taken.add(prov["code"])

    payload = {
        "generatedAt": now_ms,
        "ok": True,
        "providers": providers,
    }

    print(json.dumps(payload))


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
