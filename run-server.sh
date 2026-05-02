#!/bin/bash
# Start (or restart) the dev3 headless server + ngrok tunnel inside two
# detached tmux sessions: `dev3` (server) and `dev3-ngrok` (public tunnel).
#
# Usage:
#   ./run-server.sh              # start both
#   ./run-server.sh stop         # stop both
#   ./run-server.sh status       # show port + public URL
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

mkdir -p "$LOG_DIR"

cmd_status() {
	if tmux has-session -t dev3 2>/dev/null; then
		port=$(grep -oE 'http://[^:]+:[0-9]+' "$SERVER_LOG" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
		echo "dev3 server : RUNNING (port=${port:-unknown}, code=$STATIC_CODE)"
	else
		echo "dev3 server : stopped"
	fi
	if tmux has-session -t dev3-tunnel 2>/dev/null; then
		url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
		echo "tunnel      : RUNNING (${url:-pending}/?token=$STATIC_CODE)"
	else
		echo "tunnel      : stopped"
	fi
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
	url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1)
	echo "public URL  : ${url:-pending}/?token=$STATIC_CODE"
}

case "${1:-start}" in
	start)  cmd_start ;;
	stop)   cmd_stop ;;
	status) cmd_status ;;
	*)      echo "Usage: $0 {start|stop|status}"; exit 2 ;;
esac
