#!/bin/sh
# Reconciliation must be idempotent and must propagate kernel failures.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
. "$ROOT/xkop/files/usr/lib/xkop/nft.sh"
XKOP_ROUTE_TABLE=106
XKOP_NFT_MARK=0x00200000
ROUTE=0 RULE=0 FAIL_ROUTE=0 ADDED=0
ip() {
 case "$*" in
  'route list table 106') [ "$ROUTE" = 0 ] || echo 'local default dev lo scope host' ;;
  'rule list'|'-4 rule list') [ "$RULE" = 0 ] || echo '106: from all fwmark 0x200000/0x200000 lookup 106' ;;
  'route add local 0.0.0.0/0 dev lo table 106') [ "$FAIL_ROUTE" = 0 ] || return 1; ROUTE=1 ;;
  '-4 rule add '*) RULE=1; ADDED=$((ADDED+1)) ;;
  *) return 1 ;;
 esac
}
failed=0
nft_routing_rule
nft_routing_rule
if [ "$ADDED" != 1 ]; then echo 'FAIL repeated reconciliation duplicates policy rules'; failed=1; else echo 'ok   policy rules are idempotent'; fi
ROUTE=0 FAIL_ROUTE=1
if nft_routing_rule; then echo 'FAIL failed local route installation reported success'; failed=1; else echo 'ok   route installation failure propagates'; fi
[ "$failed" = 0 ]
