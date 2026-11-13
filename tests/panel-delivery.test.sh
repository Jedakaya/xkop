#!/bin/sh
# shellcheck shell=ash
# A package-only update must retire the legacy panel, never implicitly enable it.
set -eu
ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT INT TERM
export PANEL_FIXTURE="$t"
mkdir "$t/uci" "$t/legacy" "$t/bundle" "$t/state"
cp -R "$ROOT/client-panel/." "$t/bundle/"
chmod 755 "$t/bundle/cgi-bin/"*
echo old-vulnerable-panel > "$t/legacy/index.html"
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
sed "s|/etc/init.d/uhttpd|$t/uhttpd|g;s|/usr/lib/libustream-ssl.so|$t/tls.so|g;s|/lib/libustream-ssl.so|$t/tls.so|g;s|/tmp/xkop-panel-token|$t/token|g" "$ROOT/xkop/files/usr/lib/xkop/panel.sh" > "$t/helper"
. "$t/helper"
command -v panel_configure_bundle >/dev/null || { echo 'FAIL package panel delivery unavailable'; exit 1; }
uci set "uhttpd.main.cert=$t/cert"; uci set "uhttpd.main.key=$t/key"
panel_configure_bundle "$t/absent" "$t/bundle" "$t/state/disabled" xkop_panel 8090
[ ! -f "$t/uci/uhttpd.xkop_panel.home" ] && [ ! -f "$t/state/disabled" ]
echo 'ok bundled files do not enable optional panel'
uci set "uhttpd.xkop.home=$t/legacy"; uci set 'uhttpd.xkop.listen_http=0.0.0.0:8090'
uci set "uhttpd.xkop_panel.home=$t/legacy"; uci set 'uhttpd.xkop_panel.listen_http=0.0.0.0:8090'
echo stolen-old-token > "$t/token"
panel_configure_bundle "$t/legacy" "$t/bundle" "$t/state/enabled" xkop_panel 8090
[ "$(uci get uhttpd.xkop_panel.home)" = "$t/bundle" ]
[ ! -f "$t/uci/uhttpd.xkop.home" ] && [ ! -f "$t/uci/uhttpd.xkop_panel.listen_http" ]
[ -f "$t/state/enabled" ] && [ ! -f "$t/token" ]
[ "$(cat "$t/legacy/index.html")" = old-vulnerable-panel ]
cmp "$ROOT/client-panel/cgi-bin/auth" "$(uci get uhttpd.xkop_panel.home)/cgi-bin/auth"
echo 'ok package-only update serves bundled fixes and preserves unserved legacy rollback files'
before=$(wc -l < "$t/reloads")
panel_configure_bundle "$t/absent" "$t/bundle" "$t/state/enabled" xkop_panel 8090
[ "$(wc -l < "$t/reloads")" = "$before" ]
echo 'ok persistent opt-in survives removal of legacy document root'
mv "$t/bundle/cgi-bin/auth" "$t/saved-auth"
if panel_configure_bundle "$t/legacy" "$t/bundle" "$t/state/enabled" xkop_panel 8090; then echo 'FAIL incomplete bundle accepted'; exit 1; fi
[ ! -f "$t/uci/uhttpd.xkop_panel.home" ]
echo 'ok partial package extraction disables panel instead of serving old CGI'
mv "$t/saved-auth" "$t/bundle/cgi-bin/auth"
panel_configure_bundle "$t/legacy" "$t/bundle" "$t/state/enabled" xkop_panel 8090
echo 'rollback-release' >> "$t/bundle/index.html"
panel_configure_bundle "$t/legacy" "$t/bundle" "$t/state/enabled" xkop_panel 8090
tail -n 1 "$(uci get uhttpd.xkop_panel.home)/index.html" | grep -qx rollback-release
echo 'ok package rollback changes served bundle without stale copied assets'
# Installer release path must use package bytes even with the network unavailable.
sed -n '/^install_client_panel()/,/^}/p' "$ROOT/install.sh" > "$t/install-function"
. "$t/install-function"
XKOP_LIB_DIR="$t"; cp "$t/helper" "$t/panel.sh"
PANEL_BUNDLE="$t/bundle"; PANEL_MARKER="$t/state/installer-enabled"
PANEL_ROOT="$t/installer-root"; PANEL_PORT=8090; PANEL_UHTTPD_SECTION=xkop_panel
INSTALLED_FROM=release; XKOP_PANEL=1
warn() { :; }; note() { :; }; sleep() { :; }; curl() { return 0; }
fetch_repo_file() { echo network-request >> "$t/network"; return 1; }
download_panel_into() { echo network-request >> "$t/network"; return 1; }
configure_panel_uhttpd() { panel_configure_bundle "$PANEL_ROOT" "$PANEL_BUNDLE" "$PANEL_MARKER" "$PANEL_UHTTPD_SECTION" "$PANEL_PORT"; }
install_client_panel
[ ! -f "$t/network" ] && [ -f "$PANEL_MARKER" ]
[ "$(uci get uhttpd.xkop_panel.home)" = "$t/bundle" ]
echo 'ok package installer activates bundle without downloading a second panel'
rm "$t/bundle/cgi-bin/auth"
if install_client_panel; then echo 'FAIL installer accepted partial package bundle'; exit 1; fi
[ ! -f "$t/network" ] && [ ! -f "$t/uci/uhttpd.xkop_panel.home" ]
echo 'ok installer fails closed for partial package bundle without network fallback'
cp "$ROOT/client-panel/cgi-bin/auth" "$t/bundle/cgi-bin/auth"
chmod 755 "$t/bundle/cgi-bin/auth"
touch "$t/blocker"
uci set "uhttpd.xkop_panel.home=$t/legacy"
if panel_configure_bundle "$t/legacy" "$t/bundle" "$t/blocker/enabled" xkop_panel 8090; then echo 'FAIL marker persistence failure hidden'; exit 1; fi
[ ! -f "$t/uci/uhttpd.xkop_panel.home" ]
echo 'ok failed activation persistence disables listener without changing bundle'
mkdir "$t/token"
uci set "uhttpd.xkop_panel.home=$t/legacy"
if panel_configure_bundle "$t/legacy" "$t/bundle" "$t/state/enabled" xkop_panel 8090; then echo 'FAIL token retirement failure hidden'; exit 1; fi
[ ! -f "$t/uci/uhttpd.xkop_panel.home" ]
rmdir "$t/token"
echo 'ok failed token retirement disables legacy listener'
sed -n '/^panel_configure_uhttpd()/,/^}/p;/^panel_present()/,/^}/p;/^panel_remove_uhttpd()/,/^}/p' "$ROOT/xkop/files/usr/lib/xkop/service.sh" > "$t/service-functions"
. "$t/service-functions"
XKOP_PANEL_ROOT="$t/absent"; XKOP_PANEL_BUNDLE="$t/bundle"
XKOP_PANEL_MARKER="$t/state/enabled"; XKOP_PANEL_SECTION=xkop_panel; XKOP_PANEL_PORT=8090
panel_present
panel_configure_uhttpd
[ "$(uci get uhttpd.xkop_panel.home)" = "$t/bundle" ]
echo 'ok actual service hook restores opted-in package bundle'
uci set "uhttpd.xkop.home=$t/bundle"
panel_remove_uhttpd
[ ! -f "$t/uci/uhttpd.xkop_panel.home" ] && [ ! -f "$t/uci/uhttpd.xkop.home" ]
[ -f "$XKOP_PANEL_MARKER" ]
echo 'ok package removal hook stops both listeners while retaining opt-in state'
