#!/bin/sh
set -eu
ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
JQ=${JQ:-jq}
acl="$ROOT/luci-app-xkop/root/usr/share/rpcd/acl.d/luci-app-xkop.json"
"$JQ" -e '.["luci-app-xkop"] | (.read.file["/usr/bin/xkop"] == null) and (.read.file["/etc/init.d/xkop"] == null) and (.write.file["/usr/bin/xkop"] == ["exec"])' "$acl" >/dev/null || { echo 'FAIL read-only ACL allows mutation'; exit 1; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT INT TERM
cat > "$t/xkop" <<'EOF'
#!/bin/sh
printf '%s\n' "$@"
EOF
chmod +x "$t/xkop"
sed "s|/usr/bin/xkop|$t/xkop|g" "$ROOT/luci-app-xkop/root/usr/libexec/xkop-read" > "$t/read"
for command in dashboard stats nodes subscriptions get_status global_check; do
    [ "$(sh "$t/read" "$command")" = "$command" ]
    if sh "$t/read" "$command" stop >/dev/null; then echo "FAIL extra arguments $command"; exit 1; fi
done
for command in service stop restart configure canary select subscription_update update prepare teardown keep; do
    if sh "$t/read" "$command" >/dev/null; then echo "FAIL read wrapper allows $command"; exit 1; fi
done
[ "$(sh "$t/read" explain 'example.org')" = "$(printf 'explain\nexample.org')" ]
[ "$(sh "$t/read" recent 20)" = "$(printf 'recent\n20')" ]
if sh "$t/read" recent stop >/dev/null; then echo 'FAIL invalid recent argument'; exit 1; fi
echo 'PASS read-only command boundary and ACL'
