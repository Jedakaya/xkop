#!/bin/sh
# shellcheck shell=ash
set -eu
ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT INT TERM
export PANEL_FIXTURE="$t"
mkdir "$t/uci" "$t/www"
echo page > "$t/www/index.html"
echo cert > "$t/cert"; echo key > "$t/key"; echo tls > "$t/tls.so"
cat > "$t/uhttpd" <<'EOF'
#!/bin/sh
echo reload >> "$PANEL_FIXTURE/reloads"
EOF
chmod +x "$t/uhttpd"
ubus() { :; }
uci() {
    [ "${1:-}" != -q ] || shift
    local op=$1 key=${2:-} entry value
    case "$op" in
        get) cat "$t/uci/$key" 2>/dev/null ;;
        set|add_list) entry=${key%%=*}; value=${key#*=}; printf '%s' "$value" > "$t/uci/$entry" ;;
        delete) rm -f "$t/uci/$key" "$t/uci/$key."* ;;
        commit) : ;;
        *) return 1 ;;
    esac
}
helper="$ROOT/xkop/files/usr/lib/xkop/panel.sh"
if [ ! -f "$helper" ]; then echo 'FAIL HTTPS migration helper absent'; exit 1; fi
sed "s|/etc/init.d/uhttpd|$t/uhttpd|g;s|/usr/lib/libustream-ssl.so|$t/tls.so|g;s|/lib/libustream-ssl.so|$t/tls.so|g" "$helper" > "$t/helper"
. "$t/helper"
uci set "uhttpd.main.cert=$t/cert"; uci set "uhttpd.main.key=$t/key"
uci set "uhttpd.xkop.home=$t/www"; uci set 'uhttpd.xkop.listen_http=0.0.0.0:8090'
uci set "uhttpd.xkop_panel.home=$t/www"; uci set 'uhttpd.xkop_panel.listen_http=0.0.0.0:8090'
panel_tls_configure "$t/www" xkop_panel 8090
[ ! -f "$t/uci/uhttpd.xkop.home" ]
[ ! -f "$t/uci/uhttpd.xkop_panel.listen_http" ]
[ "$(uci get uhttpd.xkop_panel.listen_https)" = '0.0.0.0:8090' ]
[ "$(uci get uhttpd.xkop_panel.cert)" = "$t/cert" ]
[ "$(uci get uhttpd.xkop_panel.key)" = "$t/key" ]
[ "$(wc -l < "$t/reloads" | tr -d ' ')" -eq 1 ]
panel_tls_configure "$t/www" xkop_panel 8090
[ "$(wc -l < "$t/reloads" | tr -d ' ')" -eq 1 ]
rm "$t/cert"
if panel_tls_configure "$t/www" xkop_panel 8090; then echo 'FAIL missing certificate accepted'; exit 1; fi
[ ! -f "$t/uci/uhttpd.xkop_panel.home" ]
[ "$(wc -l < "$t/reloads" | tr -d ' ')" -eq 2 ]
echo cert > "$t/cert"; rm "$t/tls.so"
if panel_tls_configure "$t/www" xkop_panel 8090; then echo 'FAIL missing TLS library accepted'; exit 1; fi
[ ! -f "$t/uci/uhttpd.xkop_panel.home" ]
echo 'PASS HTTPS migration, idempotence and fail-closed prerequisites'
