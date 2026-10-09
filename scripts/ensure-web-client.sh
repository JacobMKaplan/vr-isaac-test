#!/bin/bash
# Make sure the CloudXR web client (index.html + bundle.js) is cached in $STATIC_DIR and patched.
# Used by setup.sh and run-demo.sh. Exit 0 when ready.
#
# Why: the isaacteleop launcher downloads from nvidia.github.io/IsaacTeleop/..., which now 404s
# (the project moved to IsaacCapture), and Quest Browser can drop the trailing slash on /client/,
# which breaks the page's relative bundle.js path. <base href="/client/"> fixes the latter.
set -euo pipefail
DIR=$(dirname "$(dirname "$(readlink -f "$0")")")
# shellcheck source=../config.sh
source "$DIR/config.sh"

mkdir -p "$STATIC_DIR"
for f in index.html bundle.js; do
    if [ ! -s "$STATIC_DIR/$f" ]; then
        echo "    Downloading web client $f (v$TELEOP_VER)"
        curl -fsSL -o "$STATIC_DIR/$f.part" "$CLIENT_URL/$f"
        mv "$STATIC_DIR/$f.part" "$STATIC_DIR/$f"
        [ "$f" = index.html ] && rm -f "$STATIC_DIR/index.html.orig"
    fi
done
if ! grep -q '<base href="/client/">' "$STATIC_DIR/index.html"; then
    [ -f "$STATIC_DIR/index.html.orig" ] || cp "$STATIC_DIR/index.html" "$STATIC_DIR/index.html.orig"
    sed -i '0,/<head>/s//<head><base href="\/client\/">/' "$STATIC_DIR/index.html"
fi
