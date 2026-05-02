#!/bin/bash
# Start (or restart) the dev3 headless server + Cloudflare quick tunnel
# inside two detached tmux sessions: `dev3` (server) and `dev3-tunnel`.
# After the tunnel comes up, publish the URL to a public gist so the
# stable redirector at https://roihala.github.io/dev3-go/ always points
# at the live tunnel — that is the URL to bookmark.
#
# Usage:
#   ./run-server.sh              # start both + publish URL
#   ./run-server.sh stop         # stop both
#   ./run-server.sh status       # show port + public URL + stable URL
#   ./run-server.sh publish      # only re-publish the current URL to the gist
#
# Idempotent: if a session is already running it is killed first.

DEV3_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$DEV3_DIR/dist"
DEV3_BIN="$HOME/bin/dev3"
STATIC_CODE="${DEV3_STATIC_CODE:-letmein-roi-2026}"
LOG_DIR="$HOME/.dev3.0/logs"
SERVER_LOG="$LOG_DIR/run-server.log"
TUNNEL_LOG="$LOG_DIR/cloudflared.log"
CLOUDFLARED="${CLOUDFLARED:-$HOME/bin/cloudflared}"

# Stable forever URL infra:
#   STABLE_URL  → bookmark this. GitHub Pages redirector reading from GIST_ID.
#   GIST_ID     → public gist holding the live tunnel URL (file: dev3-url.txt).
#                 run-server.sh writes the live URL on every start so the
#                 redirector resolves to it.
STABLE_URL="https://roihala.github.io/dev3-go/"
GIST_ID="${DEV3_GIST_ID:-c6581d94fbc1c5e78c8dba23b256b0b6}"
GIST_FILE="dev3-url.txt"

mkdir -p "$LOG_DIR"

current_tunnel_url() {
	grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1
}

current_full_url() {
	url=$(current_tunnel_url)
	[ -n "$url" ] && echo "${url}/?token=$STATIC_CODE"
}

publish_url() {
	full=$(current_full_url)
	if [ -z "$full" ]; then
		echo "publish: no live tunnel URL found in $TUNNEL_LOG — skipping" >&2
		return 1
	fi
	if ! command -v gh >/dev/null 2>&1; then
		echo "publish: gh CLI not found — skipping gist update" >&2
		return 1
	fi
	tmp="$(mktemp)"
	echo "$full" >"$tmp"
	# `gh gist edit -a` replaces an existing file's content; pipe in via stdin.
	if gh gist edit "$GIST_ID" -f "$GIST_FILE" "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		echo "publish: gist updated → $full"
	else
		rm -f "$tmp"
		echo "publish: gh gist edit failed — gist not updated" >&2
		return 1
	fi
}

cmd_status() {
	if tmux has-session -t dev3 2>/dev/null; then
		port=$(grep -oE 'http://[^:]+:[0-9]+' "$SERVER_LOG" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
		echo "dev3 server : RUNNING (port=${port:-unknown}, code=$STATIC_CODE)"
	else
		echo "dev3 server : stopped"
	fi
	if tmux has-session -t dev3-tunnel 2>/dev/null; then
		full=$(current_full_url)
		echo "tunnel      : RUNNING (${full:-pending})"
	else
		echo "tunnel      : stopped"
	fi
	echo "stable URL  : $STABLE_URL  (bookmark this — auto-redirects to live tunnel)"
}

cmd_stop() {
	tmux kill-session -t dev3 2>/dev/null || true
	tmux kill-session -t dev3-tunnel 2>/dev/null || true
	# Clean up legacy ngrok processes if any are still around.
	pkill -f 'ngrok http' 2>/dev/null || true
	echo "stopped."
}

cmd_start() {
	cmd_stop
	sleep 1
	tmux new-session -d -s dev3 -x 220 -y 50 \
		"DEV3_VIEWS_DIR=$DIST_DIR DEV3_REMOTE_STATIC_CODE=$STATIC_CODE $DEV3_BIN remote --static-code=$STATIC_CODE 2>&1 | tee $SERVER_LOG"
	# wait for the server banner to land
	for _ in $(seq 1 20); do
		grep -q 'http://.*token=' "$SERVER_LOG" 2>/dev/null && break
		sleep 0.5
	done
	port=$(grep -oE 'http://[^:]+:[0-9]+' "$SERVER_LOG" | head -1 | grep -oE '[0-9]+$')
	if [ -z "$port" ]; then
		echo "FAILED — no port banner in $SERVER_LOG"
		tail -20 "$SERVER_LOG"
		exit 1
	fi
	echo "dev3 server : http://localhost:$port/?token=$STATIC_CODE"
	if [ ! -x "$CLOUDFLARED" ]; then
		echo "tunnel      : SKIPPED — $CLOUDFLARED not executable"
		echo "stable URL  : $STABLE_URL  (won't update — no tunnel)"
		return
	fi
	# Cloudflare quick tunnel (trycloudflare.com) — no browser interstitial
	# unlike ngrok-free, which intercepts every visitor with a warning page
	# the SPA can't bypass.
	tmux new-session -d -s dev3-tunnel -x 200 -y 50 \
		"$CLOUDFLARED tunnel --url http://localhost:$port 2>&1 | tee $TUNNEL_LOG"
	for _ in $(seq 1 30); do
		grep -q 'trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null && break
		sleep 1
	done
	full=$(current_full_url)
	echo "public URL  : ${full:-pending}"
	# Publish to gist so the stable redirector resolves to the new URL.
	publish_url || true
	echo "stable URL  : $STABLE_URL  (bookmark this — auto-redirects to live tunnel)"
}

case "${1:-start}" in
	start)   cmd_start ;;
	stop)    cmd_stop ;;
	status)  cmd_status ;;
	publish) publish_url ;;
	*)       echo "Usage: $0 {start|stop|status|publish}"; exit 2 ;;
esac
