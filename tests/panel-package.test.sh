#!/bin/sh
# Execute the package install recipe on the same source layout as both SDK images.
set -eu
ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT INT TERM
for format in apk ipk; do
    package="$t/$format/package"
    target="$t/$format/root"
    mkdir -p "$package" "$target"
    cp -R "$ROOT/xkop/." "$package/"
    # Resolve Docker's actual COPY destination, rather than assuming sibling files
    # are present inside the SDK package source directory.
    destination=$(awk '$1 == "COPY" && $2 == "./client-panel" { print $3 }' "$ROOT/Dockerfile-$format")
    case "$destination" in
        /builder/package/feeds/utilities/xkop/*)
            relative=${destination#/builder/package/feeds/utilities/xkop/}
            mkdir -p "$package/$relative"
            cp -R "$ROOT/client-panel/." "$package/$relative/"
            ;;
        *) echo "FAIL $format Docker context omits panel source"; exit 1 ;;
    esac
    sed -n '/^define Package\/xkop\/install$/,/^endef$/p' "$ROOT/xkop/Makefile" \
        | sed '1d;$d' \
        | sed -e 's/$(INSTALL_DIR)/mkdir -p/g' -e 's/$(INSTALL_BIN)/install -m 755/g' \
            -e 's/$(INSTALL_DATA)/install -m 644/g' -e 's/$(INSTALL_CONF)/install -m 600/g' \
            -e 's/$(CP)/cp -R/g' -e "s|\$(1)|$target|g" -e 's/$(PKG_VERSION)/fixture/g' > "$t/recipe"
    (cd "$package"; sh -e "$t/recipe")
    for source in "$ROOT/client-panel/index.html" "$ROOT"/client-panel/cgi-bin/*; do
        relative=${source#"$ROOT/client-panel/"}
        installed="$target/usr/share/xkop/client-panel/$relative"
        cmp "$source" "$installed"
        case "$relative" in cgi-bin/*) [ -x "$installed" ] ;; esac
    done
    [ ! -e "$target/etc/xkop/panel-enabled" ] && [ ! -d "$target/www-xkop" ]
    echo "ok $format package recipe installs exact executable panel bundle without enabling it"
done
