#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PKG_TYPE="Plasma/Applet"
PKG_ID="com.gar.ompusage"

# Ensure the fetch script is executable (guard if missing).
FETCH="contents/scripts/usage-fetch.py"
if [[ -f "$FETCH" ]]; then
    chmod +x "$FETCH"
fi

# Install or upgrade depending on whether the plasmoid is already registered.
if kpackagetool6 --type "$PKG_TYPE" --list | grep -q "$PKG_ID"; then
    echo "Upgrading $PKG_ID ..."
    kpackagetool6 --type "$PKG_TYPE" --upgrade .
else
    echo "Installing $PKG_ID ..."
    kpackagetool6 --type "$PKG_TYPE" --install .
fi

cat <<EOF

Done. Next steps:
  1. Right-click the panel -> Add or Manage Widgets
  2. Search for 'OMP Usage'
  3. Drag the widget onto your panel

After an --upgrade, a plasmashell restart may help pick up changes:
  kquitapp6 plasmashell 2>/dev/null; (kstart plasmashell >/dev/null 2>&1 &)
EOF
