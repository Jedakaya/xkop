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
            | sed -n 's/^xkop - \([0-9][^ ]*\)-r[0-9]*$/\1/p' | head -n 1
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
# права читаться как «не поместится» — иначе он заблокирует любое обновление.
update_would_fit() {
    local out rc

    if command -v apk > /dev/null 2>&1; then
        out=$(apk add --allow-untrusted --upgrade --simulate "$1" 2>&1)
    else
        out=$(opkg install --noaction "$1" 2>&1)
    fi
    rc=$?

    [ $rc -eq 0 ] && return 0

    if printf '%s' "$out" | grep -qiE 'unrecognized option|invalid option|unknown option|usage:'; then
        return 0
    fi

    log_error "менеджер отказал на сухом прогоне: $(printf '%s' "$out" | head -n 1)"
    return 1
}

update_install_file() {
    local file="$1"

    [ -s "$file" ] || return 1

    update_would_fit "$file" || return 2

    if command -v apk > /dev/null 2>&1; then
        apk add --allow-untrusted --upgrade "$file" > /dev/null 2>&1
    else
        opkg install "$file" > /dev/null 2>&1
    fi
}

# Всё нужное для отката складывается в RAM: конфигурация крошечная, а пакеты
# текущей версии скачиваются заново, а не хранятся на флэше. Роутер с парой
# свободных мегабайт не платит за эту страховку ничего.
update_stage_rollback() {
    local version format url name

    rm -rf "$XKOP_ROLLBACK_DIR"
    mkdir -p "$XKOP_ROLLBACK_DIR" || return 1

    [ -f "$XKOP_CONFIG" ] || true
    [ -f /etc/config/xkop ] && cp /etc/config/xkop "$XKOP_ROLLBACK_DIR/config"

    version=$(update_installed_version)
    if [ -z "$version" ]; then
        log_info "установленная версия не определяется, откат будет только по конфигурации"
        return 0
    fi

    printf '%s' "$version" > "$XKOP_ROLLBACK_DIR/version"
    format=$(update_pkg_format)

    for name in xkop luci-app-xkop; do
        url="https://github.com/$(update_repo)/releases/download/v${version}/${name}-${version}-r1.${format}"
        if ! curl -fsSL --max-time 120 -o "$XKOP_ROLLBACK_DIR/${name}.${format}" "$url" 2> /dev/null; then
            rm -f "$XKOP_ROLLBACK_DIR/${name}.${format}" "$XKOP_ROLLBACK_DIR/version"
            log_info "пакет $name $version недоступен, откат будет только по конфигурации"
            return 0
        fi
    done

    return 0
}

# Обновление считается удачным, только когда роутер снова работает.
# «Пакет установился» этого не доказывает.
#
# Перезапуск делается явно, а не выводится из смены pid: хук пакета делает
# только start, и у уже работающего движка pid не меняется — требование смены
# pid превращало каждое здоровое обновление в неудачное.
update_healthy() {
    [ -x /usr/bin/xkop ] || return 1

    /etc/init.d/xkop restart > /dev/null 2>&1
    engine_wait 45
}

update_rollback() {
    local version format name restored=0

    log_warn "обновление не заработало, откатываю"

    version=$(cat "$XKOP_ROLLBACK_DIR/version" 2> /dev/null)
    format=$(update_pkg_format)

    if [ -n "$version" ]; then
        for name in xkop luci-app-xkop; do
            [ -s "$XKOP_ROLLBACK_DIR/${name}.${format}" ] || continue
            update_install_file "$XKOP_ROLLBACK_DIR/${name}.${format}" && restored=1
        done
    fi

    if [ -s "$XKOP_ROLLBACK_DIR/config" ]; then
        cp "$XKOP_ROLLBACK_DIR/config" /etc/config/xkop
    fi

    /etc/init.d/xkop restart > /dev/null 2>&1

    if [ "$restored" -eq 1 ] && engine_wait 45; then
        log_info "откат на версию $version удался"
        return 0
    fi

    log_error "откат не помог: роутер остаётся без работающего движка"
    return 1
}

update_apply() {
    local format arch latest installed work engine_url xkop_url luci_url
    local engine_updated=0

    format=$(update_pkg_format)
    arch=$(update_router_arch)
    installed=$(update_installed_version)

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

    if [ -z "$xkop_url" ]; then
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
    [ -n "$luci_url" ] && curl -fsSL --max-time 120 -o "$work/luci.$format" "$luci_url" 2> /dev/null
    [ -n "$engine_url" ] && curl -fsSL --max-time 300 -o "$work/engine.$format" "$engine_url" 2> /dev/null

    update_stage_rollback

    if [ -s "$work/engine.$format" ]; then
        if update_install_file "$work/engine.$format"; then
            engine_updated=1
        else
            log_warn "движок не обновился, продолжаю с прежним"
        fi
    fi

    if ! update_install_file "$work/xkop.$format"; then
        rm -rf "$work"
        update_rollback
        jq -nc '{ok: false, error: "install_failed", detail: {package: "xkop"}, rolled_back: true}'
        return 0
    fi

    [ -s "$work/luci.$format" ] && update_install_file "$work/luci.$format" > /dev/null 2>&1
    rm -rf "$work"

    if update_healthy; then
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
