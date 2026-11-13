#!/bin/sh
# shellcheck shell=ash
# Обновление.
#
# Версию знает пакетный менеджер, а не мы: он умеет её сравнить, поставить
# новую и убрать старую. Поэтому обновление идёт пакетами — см. docs/install.md.
#
# Форма взята из podkop, где она куплена днём отладки на живых роутерах,
# и каждое правило здесь нарушается ровно один раз:
#
#   - качать в /tmp, это RAM: отказ не должен стоить флэша и не должен
#     оставлять роутер на середине;
#   - место проверять ПОСЛЕ загрузки и ДО установки, по реальному размеру
#     файла: фиксированные пятнадцать мегабайт сами по себе отказывали
#     роутерам, которым нужен был мегабайт;
#   - обновление на месте требует места под весь новый размер, а не под
#     разницу версий: менеджер распаковывает новое рядом со старым;
#   - откат готовится ДО обновления и живёт в RAM: он нужен в пределах этой
#     сессии, переживать перезагрузку ему незачем;
#   - «пакет установился без ошибки» и «оно работает» — разные вещи, и
#     различать их и есть смысл проверки здоровья.

XKOP_ROLLBACK_DIR='/tmp/xkop-rollback'

update_repo() {
    printf '%s' "${XKOP_REPO:-Jedakaya/xkop}"
}

update_pkg_format() {
    if command -v apk > /dev/null 2>&1; then printf 'apk'; else printf 'ipk'; fi
}

update_router_arch() {
    local arch=""
    [ -r /etc/os-release ] && arch=$(. /etc/os-release 2> /dev/null && echo "${OPENWRT_ARCH:-}")
    [ -n "$arch" ] || arch=$(uname -m 2> /dev/null)
    printf '%s' "$arch"
}

# Суффикс релиза снимается одинаково для обоих менеджеров. В podkop
# несовпадение здесь давало адрес отката вида xkop-0.1.0-r1-r1.apk.
update_installed_version() {
    if command -v apk > /dev/null 2>&1; then
        apk list --installed 2> /dev/null \
            | sed -n 's/^xkop-\([0-9][^ ]*\)-r[0-9]* .*/\1/p' | head -n 1
    else
        opkg list-installed 2> /dev/null \
            | sed -n 's/^xkop - \([0-9][^ ]*\)-r\{0,1\}[0-9][0-9]*$/\1/p' | head -n 1
    fi
}

update_latest_json() {
    mkdir -p "$XKOP_RUN_DIR"
    curl -fsSL --max-time 30 -o "$XKOP_RUN_DIR/release.json" \
        "https://api.github.com/repos/$(update_repo)/releases/latest" 2> /dev/null
}

update_latest_version() {
    jq -r '.tag_name // empty' "$XKOP_RUN_DIR/release.json" 2> /dev/null | sed 's/^v//'
}

# Ссылка на файл релиза по началу и концу имени. Архитектура входит в имя
# пакета движка именно поэтому: без неё восемь разных файлов называются
# одинаково, и на роутере не понять, тот ли скачался.
update_asset_url() {
    jq -r --arg p "$1" --arg s "$2" \
        '[.assets[]? | select((.name | startswith($p)) and (.name | endswith($s)))]
         | first | .browser_download_url // empty' \
        "$XKOP_RUN_DIR/release.json" 2> /dev/null
}

update_check_json() {
    local installed latest

    installed=$(update_installed_version)
    [ -n "$installed" ] || installed="${XKOP_VERSION:-}"

    if ! update_latest_json; then
        jq -nc --arg installed "$installed" \
            '{ok: false, error: "releases_unreachable", installed: $installed}'
        return 0
    fi

    latest=$(update_latest_version)

    jq -nc --arg installed "$installed" --arg latest "$latest" \
        '{
            ok: true,
            installed: (if $installed == "" then null else $installed end),
            latest: (if $latest == "" then null else $latest end),
            update_available: ($latest != "" and $latest != $installed)
        }'
}

# Рабочий каталог менеджера — в RAM.
#
# Индекс и распакованный архив это ровно та временная запись, которая первой
# отказывает на почти полной флэш-памяти. На большинстве сборок /var и так
# ведёт в tmpfs, но не на всех, а сомнение здесь стоит неудавшегося
# обновления. Взято из установщика podkop.
update_prepare_ram() {
    TMPDIR=/tmp
    export TMPDIR
    mkdir -p "$XKOP_RUN_DIR" 2> /dev/null
}

# Освобождает флэш, который целиком кэш: всё перечисленное восстанавливается
# по требованию и для работы роутера не нужно. Кэш apk и списки opkg под /var
# не трогаются: там tmpfs, флэша они не стоят, а их вычистка заставит заново
# качать весь индекс — на этом в podkop начинались отказы из-за одного
# капризного фида.
update_reclaim_flash() {
    local before after freed

    before=$(df -k /overlay 2> /dev/null | awk 'NR==2 {print $4}')

    rm -rf /usr/lib/opkg/lists/* 2> /dev/null
    rm -rf /usr/lib/opkg/tmp/* 2> /dev/null
    rm -f /var/log/*.old /var/log/*.gz 2> /dev/null

    after=$(df -k /overlay 2> /dev/null | awk 'NR==2 {print $4}')
    [ -n "$before" ] && [ -n "$after" ] || return 0
    freed=$((after - before))
    [ "$freed" -gt 0 ] && log_info "освобождено кэша: ${freed} КБ"
    return 0
}

# Хватит ли места — спрашивает сам менеджер сухим прогоном.
#
# Он учитывает место, которое вернёт удаляемая старая версия, чего сравнение
# размеров не умеет: в podkop фиксированный порог сам по себе отказывал
# роутерам, которым нужен был мегабайт. Менеджер, не знающий флага, не имеет
# права менять пакеты без проверенного плана: неизвестный флаг блокирует обновление.
update_would_fit() {
    local out rc name
    name=${1##*/}; name=${name%.*}

    if command -v apk > /dev/null 2>&1; then
        out=$(apk --no-network add --allow-untrusted --simulate "$1" 2>&1)
    else
        out=$(opkg install --noaction "$1" 2>&1)
    fi
    rc=$?

    if [ "$rc" -eq 0 ]; then
        # Reject dependency changes outside the prepared rollback set. Each
        # step only installs its named package; removals are never accepted.
        printf '%s\n' "$out" | awk -v expected="$name" '
          /^\([0-9]+\/[0-9]+\) / {op=$2; package=$3; check=1}
          /^(Installing|Upgrading|Downgrading|Reinstalling|Removing|Purging) / {op=$1; package=$2; check=1}
          check {if (package != expected || op !~ /^(Installing|Upgrading|Downgrading|Reinstalling)$/) bad=1; check=0}
          END {exit bad}'
        return $?
    fi

    log_error "менеджер отказал на сухом прогоне: $(printf '%s' "$out" | head -n 1)"
    return 1
}

# Хватит ли флэша, чтобы новый движок встал рядом со старым. То же правило,
# что в install.sh (engine_needs_room), и проверка держит их согласованными:
# apk распаковывает новый файл раньше, чем убирает старый, а сухой прогон
# места не проверяет. На стенде это было «No space left on device».
update_engine_needs_room() {
    local free_kb="$1" engine_kb="$2"
    case "$free_kb" in '' | *[!0-9]*) return 1 ;; esac
    case "$engine_kb" in '' | *[!0-9]*) return 1 ;; esac
    [ "$free_kb" -lt $((engine_kb + 4096)) ]
}

XKOP_ENGINE_STASH=""

# Прежний движок уходит в RAM, служба останавливается — запущенный процесс
# держит файл, и место не освободилось бы. Поднимает её update_healthy.
update_engine_make_room() {
    local engine_kb free_kb mem_kb
    [ -f /usr/bin/xray ] || return 0
    engine_kb=$(( ($(wc -c < /usr/bin/xray) + 1023) / 1024 ))
    free_kb=$(df -k /overlay 2> /dev/null | awk 'NR==2 {print $4}')
    update_engine_needs_room "$free_kb" "$engine_kb" || return 0

    mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2> /dev/null)
    case "$mem_kb" in '' | *[!0-9]*) mem_kb=0 ;; esac
    if [ "$mem_kb" -lt $((engine_kb + 32768)) ]; then
        log_warn "флэша под новый движок мало, а памяти не хватит подержать прежний"
        return 0
    fi

    log_info "флэша под новый движок мало: прежний на время установки в памяти"
    XKOP_ENGINE_STASH="/tmp/xkop-xray-room.$$"
    if ! cp /usr/bin/xray "$XKOP_ENGINE_STASH"; then
        rm -f "$XKOP_ENGINE_STASH"
        XKOP_ENGINE_STASH=""
        return 0
    fi
    /etc/init.d/xkop stop > /dev/null 2>&1
    rm -f /usr/bin/xray
}

update_engine_room_restore() {
    [ -n "$XKOP_ENGINE_STASH" ] || return 0
    if [ "$1" != "1" ]; then
        if ! cp "$XKOP_ENGINE_STASH" /usr/bin/xray || ! chmod 755 /usr/bin/xray; then
            log_error "не удалось вернуть движок; резерв сохранён: $XKOP_ENGINE_STASH"
            return 1
        fi
        log_info "прежний движок возвращён на место"
    fi
    rm -f "$XKOP_ENGINE_STASH"
    XKOP_ENGINE_STASH=""
}

update_install_file() {
    local file="$1"

    [ -s "$file" ] || return 1

    update_would_fit "$file" || return 2

    if command -v apk > /dev/null 2>&1; then
        apk --no-network add --allow-untrusted "$file" > /dev/null 2>&1
    else
        opkg install "$file" > /dev/null 2>&1
    fi
}

# Всё нужное для отката складывается в RAM: конфигурация крошечная, а пакеты
# текущей версии скачиваются заново, а не хранятся на флэше. Роутер с парой
# свободных мегабайт не платит за эту страховку ничего.
update_stage_rollback() {
    local version format url name exact arch

    rm -rf "$XKOP_ROLLBACK_DIR"
    mkdir -p "$XKOP_ROLLBACK_DIR" || return 1

    [ -f /etc/config/xkop ] && cp /etc/config/xkop "$XKOP_ROLLBACK_DIR/config" || return 1

    version=$(update_installed_version)
    [ -n "$version" ] || return 1

    printf '%s' "$version" > "$XKOP_ROLLBACK_DIR/version"
    format=$(update_pkg_format)
    arch=$(update_router_arch)
    curl -fsSL --max-time 30 -o "$XKOP_ROLLBACK_DIR/release.json" \
        "https://api.github.com/repos/$(update_repo)/releases/tags/v$version" 2>/dev/null || return 1
    [ "$#" -gt 0 ] || set -- xkop luci-app-xkop
    : > "$XKOP_ROLLBACK_DIR/packages"
    for name in "$@"; do
        exact=$(update_package_version "$name")
        [ -n "$exact" ] || return 1
        url=$(update_exact_asset "$XKOP_ROLLBACK_DIR/release.json" "$name" "$exact" "$arch" "$format")
        [ -n "$url" ] || return 1
        if ! curl -fsSL --max-time 120 -o "$XKOP_ROLLBACK_DIR/${name}.${format}" "$url" 2> /dev/null; then
            return 1
        fi
        update_validate_package "$XKOP_ROLLBACK_DIR/${name}.${format}" "$name" "$exact" "$arch" "$format" || return 1
        printf '%s %s\n' "$name" "$exact" >> "$XKOP_ROLLBACK_DIR/packages"
    done

    return 0
}

# Keep the package revision: r1 and r2 are different rollback artifacts.
update_package_version() {
    if command -v apk >/dev/null 2>&1; then
        apk list --installed 2>/dev/null | awk -v prefix="$1-" 'index($1,prefix)==1 {print substr($1,length(prefix)+1); exit}'
    else
        opkg list-installed 2>/dev/null | awk -v name="$1" '$1==name {print $3; exit}'
    fi
}

update_exact_asset() {
    jq -r --arg n "$2-$3" --arg arch "$4" --arg f "$5" --arg p "$2" '
      [.assets[]? | select(if $p == "xray-xkop" then .name == ($n+"-"+$arch+"."+$f)
        else .name == ($n+"."+$f) or .name == ($n+"-all."+$f) or .name == ($n+"-noarch."+$f) end)]
      | if length == 1 then .[0].browser_download_url else empty end' "$1"
}

update_url_version() {
    local file="${2##*/}"
    file=${file#"$1-"}
    file=${file%.*}
    file=${file%"-$3"}
    file=${file%-all}
    file=${file%-noarch}
    printf '%s' "$file"
}

update_validate_package() (
    # Reuse read-only archive inspection; it does not require fleet enrollment.
    WORK="$XKOP_RUN_DIR/update-inspect"
    mkdir -p "$WORK" || exit 1
    . "${XKOP_LIB_DIR:-/usr/lib/xkop}/fleet-native.sh"
    fleet_native_metadata "$1" "$5" "$WORK/meta.json" || exit 1
    jq -e --arg n "$2" --arg v "$3" --arg a "$4" '
      .name==$n and .version==$v and
      (.arch==$a or ($n!="xray-xkop" and (.arch=="all" or .arch=="noarch")))' "$WORK/meta.json" >/dev/null || exit 1
    fleet_native_integrity "$1" "$5"
)

update_restore_file() {
    local file="$1" name="$2" version hash cache="$XKOP_ROLLBACK_DIR/cache"
    [ -s "$1" ] || return 1
    if command -v apk >/dev/null 2>&1; then
        apk --no-network add --allow-untrusted "$file" >/dev/null 2>&1 || return 1
        # A failed extraction can leave the database at the old version.
        mkdir -p "$cache" || return 1
        apk adbdump --format json "$file" > "$cache/meta.json" 2>/dev/null || return 1
        version=$(jq -r .info.version "$cache/meta.json")
        hash=$(jq -r .info.hashes "$cache/meta.json" | cut -c 1-8)
        case "$hash" in *[!a-f0-9]*) return 1;; esac
        [ "${#hash}" -eq 8 ] || return 1
        cp "$file" "$cache/$name-$version.$hash.apk" || return 1
        apk --no-network --cache-dir "$cache" fix --allow-untrusted --reinstall "$name" >/dev/null 2>&1
    else
        opkg --force-downgrade --force-reinstall install "$1" >/dev/null 2>&1
    fi
}

# Обновление считается удачным, только когда роутер снова работает.
# «Пакет установился» этого не доказывает.
#
# Перезапуск делается явно, а не выводится из смены pid: хук пакета делает
# только start, и у уже работающего движка pid не меняется — требование смены
# pid превращало каждое здоровое обновление в неудачное.
update_healthy() {
    [ -x /usr/bin/xkop ] || return 1

    /etc/init.d/xkop restart 7>&- 9>&- > /dev/null 2>&1
    engine_wait 45
}

update_rollback() {
    local version format name exact restored=1 count=0

    log_warn "обновление не заработало, откатываю"

    version=$(cat "$XKOP_ROLLBACK_DIR/version" 2> /dev/null)
    format=$(update_pkg_format)

    [ -n "$version" ] && [ -s "$XKOP_ROLLBACK_DIR/packages" ] || return 1
    while read -r name exact; do
        count=$((count + 1))
        update_restore_file "$XKOP_ROLLBACK_DIR/${name}.${format}" "$name" || restored=0
        [ "$(update_package_version "$name")" = "$exact" ] || restored=0
    done < "$XKOP_ROLLBACK_DIR/packages"

    if [ -s "$XKOP_ROLLBACK_DIR/config" ]; then
        cp "$XKOP_ROLLBACK_DIR/config" /etc/config/xkop || restored=0
    fi
    if [ "$restored" -ne 1 ]; then
        update_engine_room_restore 0 || true
    fi

    /etc/init.d/xkop restart 7>&- 9>&- > /dev/null 2>&1

    if [ "$restored" -eq 1 ] && [ "$count" -gt 0 ] && engine_wait 45; then
        update_engine_room_restore 1 || return 1
        rm -f "$XKOP_ROLLBACK_DIR/pending"
        log_info "откат на версию $version удался"
        return 0
    fi

    log_error "откат не подтверждён; проверьте версии, журнал и сохранённый резерв"
    return 1
}

# Версия установленного пакета движка и версия того, что лежит в релизе.
#
# Движок весит тридцать с лишним мегабайт и качается в память. Скачивать его
# при каждом обновлении xkop, когда сам он не менялся, — это лишние тридцать
# мегабайт в оперативной памяти роутера, у которого её и так немного, и лишняя
# переустановка на ровном месте. Версии сравниваются по строке, которую даёт
# сам менеджер, и по имени файла в релизе: у них она одна и та же, вида
# "26.7.28-r1".
# Спрашивается менеджер, и только он.
#
# Версия самого бинарника тут не годится: движок, положенный файлом с ветки,
# менеджеру неизвестен, и задача обновления — поставить пакет на его место.
# Счесть «версия та же, качать не буду» значит навсегда оставить роутер
# с движком, о котором менеджер не знает и который он не обновит.
update_engine_installed_version() {
    if command -v apk > /dev/null 2>&1; then
        apk list --installed 2> /dev/null \
            | awk '/^xray-xkop-/ {print substr($1, 11); exit}'
    else
        opkg list-installed 2> /dev/null \
            | awk '$1 == "xray-xkop" {print $3; exit}'
    fi
}

# Без номера нашей сборки: "26.7.28-r1" и "26.7.28" — про один движок.
update_engine_version_core() {
    printf '%s' "$1" | sed 's/-r\{0,1\}[0-9][0-9]*$//'
}

update_engine_url_version() {
    local name="${1##*/}" arch="$2" format="$3"

    name="${name#xray-xkop-}"
    name="${name%-$arch.$format}"
    printf '%s' "$name"
}

update_apply() (
    # Do not hold the work lock: package hooks need it to prepare/restart Xkop.
    if ! lock_acquire update; then
        jq -nc '{ok:false,error:"update_busy"}'
        return 0
    fi
    trap 'lock_release update' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    if [ -d /etc/xkop/fleet ]; then
        # Shared with the signed transaction and managed configuration editor.
        # The descriptor is inherited by native installers if this shell dies.
        if ! command -v flock >/dev/null 2>&1; then
            jq -nc '{ok:false,error:"update_lock_unavailable"}'
            return 0
        fi
        if [ -d /etc/xkop/fleet/supervisor ]; then
            exec 7> /etc/xkop/fleet/supervisor/control.lock
            if ! flock -n 7; then
                jq -nc '{ok:false,error:"update_busy"}'
                return 0
            fi
        fi
        exec 9> /etc/xkop/fleet/transaction.lock
        if ! flock -n 9; then
            jq -nc '{ok:false,error:"update_busy"}'
            return 0
        fi
        if [ -e /etc/xkop/fleet/supervisor/queue.json ] || [ -e /etc/xkop/fleet/supervisor/session.json ]; then
            jq -nc '{ok:false,error:"update_busy"}'
            return 0
        fi
        if [ -f /etc/xkop/fleet/transaction/journal.json ]; then
            case "$(jq -r .state /etc/xkop/fleet/transaction/journal.json 2>/dev/null)" in
                committed|rolled_back) ;;
                *) jq -nc '{ok:false,error:"recovery_required"}'; return 0;;
            esac
        fi
        if [ -f /etc/xkop/fleet/configuration/current/status.json ]; then
            case "$(jq -r .state /etc/xkop/fleet/configuration/current/status.json 2>/dev/null)" in
                committed|rolled_back|rejected) ;;
                *) jq -nc '{ok:false,error:"recovery_required"}'; return 0;;
            esac
        fi
        if [ -f /etc/xkop/fleet/supervisor/active.json ]; then
            if [ "$(cat /etc/xkop/fleet/supervisor/acknowledged 2>/dev/null)" != \
                "$(jq -r .job_id /etc/xkop/fleet/supervisor/active.json 2>/dev/null)" ]; then
                jq -nc '{ok:false,error:"update_busy"}'
                return 0
            fi
        fi
    fi
    update_apply_locked
)

update_apply_locked() {
    local format arch latest installed work engine_url xkop_url luci_url
    local engine_updated=0 engine_have engine_want packages='xkop' name file url exact failed_package='' rolled_back=false

    format=$(update_pkg_format)
    arch=$(update_router_arch)
    installed=$(update_installed_version)

    if [ -e "$XKOP_ROLLBACK_DIR/pending" ]; then
        jq -nc '{ok:false,error:"recovery_required",rolled_back:false}'
        return 0
    fi

    update_prepare_ram
    update_reclaim_flash

    if ! update_latest_json; then
        jq -nc '{ok: false, error: "releases_unreachable"}'
        return 0
    fi

    latest=$(update_latest_version)
    if [ -z "$latest" ]; then
        jq -nc '{ok: false, error: "no_release"}'
        return 0
    fi

    if [ -n "$installed" ] && [ "$latest" = "$installed" ]; then
        jq -nc --arg v "$latest" '{ok: true, result: "unchanged", version: $v}'
        return 0
    fi

    xkop_url=$(update_asset_url "xkop-" ".$format")
    luci_url=$(update_asset_url "luci-app-xkop-" ".$format")
    engine_url=$(update_asset_url "xray-xkop-" "-$arch.$format")

    if [ -z "$xkop_url" ] || [ -z "$engine_url" ]; then
        jq -nc --arg arch "$arch" --arg format "$format" \
            '{ok: false, error: "no_package_for_router", detail: {arch: $arch, format: $format}}'
        return 0
    fi

    work="$XKOP_RUN_DIR/update"
    rm -rf "$work"
    mkdir -p "$work"

    # Сначала целиком в RAM, потом установка: отказ на середине загрузки
    # не должен оставлять роутер с половиной обновления.
    if ! curl -fsSL --max-time 120 -o "$work/xkop.$format" "$xkop_url" 2> /dev/null; then
        rm -rf "$work"
        jq -nc '{ok: false, error: "download_failed", detail: {package: "xkop"}}'
        return 0
    fi
    if [ -n "$(update_package_version luci-app-xkop)" ]; then
        if [ -z "$luci_url" ] || ! curl -fsSL --max-time 120 -o "$work/luci-app-xkop.$format" "$luci_url" 2>/dev/null; then
            jq -nc '{ok:false,error:"download_failed",detail:{package:"luci-app-xkop"}}'
            return 0
        fi
        packages="$packages luci-app-xkop"
    fi

    # Движок качается, только если он другой.
    if [ -n "$engine_url" ]; then
        engine_have=$(update_engine_installed_version)
        engine_want=$(update_engine_url_version "$engine_url" "$arch" "$format")

        if [ -n "$engine_have" ] && [ "$engine_have" = "$engine_want" ]; then
            log_info "движок $engine_have уже стоит, не качаю"
        else
            if ! curl -fsSL --max-time 300 -o "$work/xray-xkop.$format" "$engine_url" 2>/dev/null; then
                jq -nc '{ok:false,error:"download_failed",detail:{package:"xray-xkop"}}'
                return 0
            fi
            packages="xray-xkop $packages"
        fi
    fi

    for name in $packages; do
        case "$name" in xkop) url=$xkop_url;; luci-app-xkop) url=$luci_url;; xray-xkop) url=$engine_url;; esac
        exact=$(update_url_version "$name" "$url" "$arch")
        if ! update_validate_package "$work/$name.$format" "$name" "$exact" "$arch" "$format"; then
            jq -nc --arg name "$name" '{ok:false,error:"invalid_package",detail:{package:$name}}'
            return 0
        fi
    done
    # No package mutation is allowed until the entire old set is available.
    # Word splitting is intentional: only the three fixed package names enter this list.
    # shellcheck disable=SC2086
    if ! update_stage_rollback $packages; then
        jq -nc '{ok:false,error:"rollback_unavailable",rolled_back:false}'
        return 0
    fi
    # Keep the recovery set intact until either outcome is verified.
    : > "$XKOP_ROLLBACK_DIR/pending" || return 1
    for name in $packages; do
        file="$work/$name.$format"
        if [ "$name" = xray-xkop ]; then update_engine_make_room; fi
        if ! update_install_file "$file"; then failed_package=$name; break; fi
        [ "$name" != xray-xkop ] || engine_updated=1
    done
    if [ -n "$failed_package" ]; then
        update_rollback && rolled_back=true
        jq -nc --arg package "$failed_package" --argjson restored "$rolled_back" \
            '{ok:false,error:"install_failed",detail:{package:$package},rolled_back:$restored}'
        return 0
    fi

    if update_healthy; then
        update_engine_room_restore 1
        rm -rf "$work"
        rm -rf "$XKOP_ROLLBACK_DIR"
        jq -nc --arg v "$latest" --argjson engine "$engine_updated" \
            '{ok: true, result: "installed", version: $v, engine_updated: ($engine == 1)}'
        return 0
    fi

    if update_rollback; then
        jq -nc --arg v "$latest" \
            '{ok: false, error: "unhealthy_after_update", version: $v, rolled_back: true}'
    else
        jq -nc --arg v "$latest" \
            '{ok: false, error: "unhealthy_after_update", version: $v, rolled_back: false,
              hint: "logread -e xkop и xkop get_status"}'
    fi
}
