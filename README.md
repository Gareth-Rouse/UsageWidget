# OMP Usage

A KDE Plasma 6 panel widget that shows your current OMP usage at a glance for three providers:

- **Synthetic** — monthly usage
- **OpenAI** — 5-hour window
- **Anthropic** — 5-hour window

The compact representation shows each provider's default usage percentage on the panel. Hover for a rich tooltip with per-window detail (progress bars, reset times, and human-readable breakdowns), or click to pin it as a full popup.

## Requirements

- KDE Plasma 6
- The [`omp`](https://github.com/oh-my-pi/omp) CLI, authenticated for `synthetic`, `openai-codex`, and `anthropic`
- `python3`
- `kpackagetool6` (ships with Plasma)

## Install

```bash
./install.sh
```

The script makes the fetch script executable and then installs or upgrades the plasmoid (`com.gar.ompusage`) via `kpackagetool6`. After install, add it to your panel: right-click the panel → *Add or Manage Widgets* → search **OMP Usage** → drag it onto the panel. After an upgrade a `plasmashell` restart may help (`kquitapp6 plasmashell; kstart plasmashell`).

## Data sources

The widget runs `contents/scripts/usage-fetch.py` on a timer; the script emits a single JSON object on stdout.

- **Synthetic** — `omp token synthetic` provides the bearer key, then `GET https://api.synthetic.new/v2/quotas` with `Authorization: Bearer <key>` (urllib, 10s timeout). Monthly window is the default shown on the panel.
- **OpenAI** — `omp usage --json`, from the `openai-codex` provider row. The 5-hour window is shown by default when present.
- **Anthropic** — `omp usage --json`, from the `anthropic` provider row. The 5-hour window is shown by default when present.

`omp usage --json` is invoked once; both OpenAI and Anthropic are parsed from it.

## Default windows & color thresholds

The panel shows the **default window** per provider:

| Provider  | Default window |
|-----------|----------------|
| Synthetic | Monthly        |
| OpenAI    | 5h             |
| Anthropic | 5h             |

Percentage colors:

- **green** — `< 70%`
- **amber** — `70%–90%`
- **red** — `> 90%` or exhausted

A provider whose fetch failed shows a dim `?` instead of a number.

## Configuring the refresh interval

Right-click the widget → *Configure OMP Usage*. Set **Refresh interval (seconds)** (default `300`, minimum `30`). The widget re-runs the fetch script on that interval.

## Troubleshooting

- A dim **`?`** on a provider means that provider's fetch failed. Run the script manually to see the error:
  ```bash
  python3 contents/scripts/usage-fetch.py
  ```
  The JSON includes a per-provider `ok`/`error` field describing what went wrong (e.g. `omp` not authenticated, API timeout, network error).
- If the widget shows stale data, force a refresh by increasing and re-applying the refresh interval, or reload the widget after editing config.

## Uninstall

```bash
kpackagetool6 --type Plasma/Applet --remove com.gar.ompusage
```
