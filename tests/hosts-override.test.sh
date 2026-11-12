#!/bin/sh
# Report exact hosts aliases, including generated OpenWrt hosts files.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_HOSTS_FILE="$work/hosts"
XKOP_HOSTS_DIR="$work/generated"
mkdir -p "$XKOP_HOSTS_DIR"
cat > "$XKOP_HOSTS_FILE" <<'EOF'
# 45.155.204.190 chatgpt.com
45.155.204.190 unrelated.example chatgpt.com auth.openai.com # old override
192.0.2.1 notchatgpt.com
192.0.2.2 CHATGPT.COM.
EOF
printf '192.0.2.3 chatgpt.com\n' > "$XKOP_HOSTS_DIR/dhcp.test"
. "$ROOT/xkop/files/usr/lib/xkop/explain.sh"
result=$(explain_hosts_overrides chatgpt.com)
printf '%s' "$result" | jq -e 'length==3 and .[0].address=="45.155.204.190" and .[0].line==2 and .[2].address=="192.0.2.3"' >/dev/null || exit 1
echo 'ok   exact aliases and generated hosts are reported, comments and suffix collisions are ignored'
result=$(explain_hosts_overrides absent.example)
printf '%s' "$result" | jq -e 'length==0' >/dev/null || exit 1
echo 'ok   absent aliases produce an empty list'
