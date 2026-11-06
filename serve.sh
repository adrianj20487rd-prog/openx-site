#!/usr/bin/env bash
#
# Publish the static openX site.
#
# Serves this folder on localhost and exposes it through a Cloudflare quick
# tunnel. No account or token is needed, but the URL is temporary: it changes
# every run and stops when this script exits. See README.md for permanent hosts.
#
#   ./serve.sh            # port 8787
#   PORT=9000 ./serve.sh
#
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8787}"
TOOLS=".tools"
LOG="$TOOLS/tunnel.log"
mkdir -p "$TOOLS"

find_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1; then
        command -v cloudflared
        return
    fi
    if [ -x "$TOOLS/cloudflared" ]; then
        echo "$TOOLS/cloudflared"
        return
    fi

    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$arch" in
        arm64 | aarch64) arch=arm64 ;;
        x86_64 | amd64) arch=amd64 ;;
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
    esac

    local base="https://github.com/cloudflare/cloudflared/releases/latest/download"

    case "$os" in
        darwin)
            echo "downloading cloudflared ($os/$arch)..." >&2
            curl -fsSL --max-time 300 "$base/cloudflared-$os-$arch.tgz" -o "$TOOLS/cloudflared.tgz"
            tar -xzf "$TOOLS/cloudflared.tgz" -C "$TOOLS"
            ;;
        linux)
            echo "downloading cloudflared ($os/$arch)..." >&2
            curl -fsSL --max-time 300 "$base/cloudflared-$os-$arch" -o "$TOOLS/cloudflared"
            ;;
        *)
            echo "unsupported OS: $os - install cloudflared manually" >&2
            exit 1
            ;;
    esac

    chmod +x "$TOOLS/cloudflared"
    echo "$TOOLS/cloudflared"
}

CF="$(find_cloudflared)"

# Keep the published checksum file in step with the archive.
if command -v shasum >/dev/null 2>&1; then
    (cd download && shasum -a 256 ./*.zip >SHA256SUMS)
fi

python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP_PID=$!
TUNNEL_PID=""

cleanup() {
    kill "$HTTP_PID" 2>/dev/null || true
    if [ -n "$TUNNEL_PID" ]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 25); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
        break
    fi
    sleep 0.2
done

: >"$LOG"
"$CF" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >"$LOG" 2>&1 &
TUNNEL_PID=$!

URL=""
for _ in $(seq 1 60); do
    URL="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | head -n1 || true)"
    if [ -n "$URL" ]; then
        break
    fi
    sleep 0.5
done

if [ -z "$URL" ]; then
    echo "the tunnel did not come up; log follows:" >&2
    tail -n 20 "$LOG" >&2
    exit 1
fi

echo
echo "  openX site:  $URL"
echo "  local:       http://127.0.0.1:$PORT/"
echo
echo "Both stop with Ctrl+C. The URL is temporary - it changes on the next run."
echo "For a permanent address, see README.md (any static host works)."
echo

wait "$TUNNEL_PID"
