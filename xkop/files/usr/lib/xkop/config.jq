# Router state -> Xray configuration.
#
# Input is one object assembled by config.sh from uci and from the subscription
# pool, so that everything uncertain - what the user configured, which servers
# survived - is decided before this program runs and nothing here has to guess:
#
#   {settings: {...}, pool: [server, ...], bindings: [{profile, channel}, ...]}
#
# Output is a complete configuration. It is never installed unvalidated: the
# caller runs "xray run -test" on it first, and a configuration the engine
# rejects is a router without an engine.
#
# Field names are taken from the engine's own JSON schema (infra/conf), not
# from documentation or memory. The traps that cost the most:
#   - REALITY builds only over RAW, XHTTP and gRPC;
#   - the transports h2, http and quic are gone and raise an error;
#   - Hysteria 2 is protocol "hysteria" with "version": 2.
# The subscription parser already drops links that would violate those, so
# whatever reaches the pool here can be emitted as it came.

def service_tags: {
    direct: "direct",
    block: "block",
    dns: "dns-out",
    metrics: "metrics-out"
};

def settings: .settings;

# Only tags of real proxy nodes. The balancer and the observatory both work by
# prefix, and every full tag is a prefix of itself - listing them outright is
# the only honest way when names come from a subscription and have no shape.
def node_tags: [ .pool[]?.tag ];

# The access log records one line per connection, and in it the outbound the
# engine actually chose. That is the difference between explaining a route and
# guessing at one: the answer comes from what happened, not from our reading of
# our own rules. It goes to RAM and is trimmed on a schedule.
# "none" гасит журнал доступа вместе со всем остальным.
#
# Проверено на живом движке: при loglevel "none" файл журнала доступа
# не создаётся вовсе, при "error" и "warning" - пишется. То есть выбор
# «молчать» в настройках тихо убивал разбор маршрута, и команда честно
# отвечала «проба сделана, но записи о ней нет», не понимая почему.
#
# Молчать и вести журнал доступа одновременно движок не умеет. Раз журнал
# нужен - берём самый тихий уровень, при котором он пишется.
def log_level:
    (settings.log_level // "warning") as $level
    | if $level == "none" and (settings.access_log // "1") == "1"
      then "error" else $level end;

def log_section:
    {
        loglevel: log_level,
        access: (if (settings.access_log // "1") == "1"
                 then (settings.access_log_path // "/tmp/xkop/access.log")
                 else "none" end)
    };

# Loopback only, and there to answer one question: what does the engine do with
# this name. The explain command sends a probe through it and reads the answer
# out of the access log.
def probe_inbound:
    {
        tag: "probe-in",
        protocol: "socks",
        listen: "127.0.0.1",
        port: (settings.probe_port // 10809),
        settings: {udp: false},
        sniffing: {enabled: true, destOverride: ["http", "tls"], routeOnly: true}
    };

# Counters are what the dashboard is built on. Without the stats object the
# metrics endpoint has nothing to serve, and without the policy switches the
# counters stay at zero - both halves are needed, see docs/stats.md.
def stats_section: {};

# Буферы. Без этого раздела движок берёт свои умолчания, а они рассчитаны
# на настольную машину: 512 КБ на каждое направление каждого соединения.
#
# На роутере, через который идёт весь трафик, это сотни мегабайт: движок
# вырос до 350 МБ при 496 МБ всего, ядро вызвало OOM-killer и убило его,
# админка перестала отвечать, а роутер ушёл в перезагрузку. Задержки узлов
# при этом выросли втрое - и я принял это за качество подписки, хотя это
# задыхался сам роутер.
#
# Числа - те же, что в руководствах по Xray на роутерах: буфер в килобайтах,
# рукопожатие и простой в секундах. uplinkOnly и downlinkOnly - сколько ждать
# после закрытия одной стороны; секунда вместо умолчальных двух и пяти
# освобождает соединения заметно раньше.
def policy_section:
    {
        levels: {
            "0": {
                handshake: (settings.handshake_seconds // 4),
                connIdle: (settings.conn_idle_seconds // 300),
                uplinkOnly: 1,
                downlinkOnly: 1,
                bufferSize: (settings.buffer_size_kb // 4)
            }
        },
        system: {
            statsInboundUplink: true,
            statsInboundDownlink: true,
            statsOutboundUplink: true,
            statsOutboundDownlink: true
        }
    };

def metrics_section:
    {tag: service_tags.metrics, listen: "127.0.0.1:\(settings.metrics_port // 11111)"};

# The engine's own control interface. Two things need it and neither can be
# done any other way: asking the balancer which node it is on, and telling it
# to stay on one. Bound to the loopback - it is unauthenticated and has no
# business being reachable from anywhere else.
# ObservatoryService is listed only when there is an observatory to serve.
# Asking for a service whose feature is absent makes the engine refuse the
# whole configuration with "not all dependencies are resolved" - the same trap
# as a balancer without an observatory, and it shows up exactly when the pool
# is empty, which is the moment the router most needs to come up.
def api_section:
    {
        tag: "api",
        listen: "127.0.0.1:\(settings.api_port // 11112)",
        services: (
            ["RoutingService", "StatsService"]
            + (if (node_tags | length) > 0 then ["ObservatoryService"] else [] end)
        )
    };

# Traffic arrives already redirected by nftables, so the inbound only has to
# accept it. followRedirect is what makes the original destination survive the
# redirect, and sniffing is what turns it back into a domain for the rules.
def tproxy_inbound:
    {
        tag: "tproxy-in",
        protocol: "dokodemo-door",
        listen: (settings.tproxy_address // "127.0.0.1"),
        port: (settings.tproxy_port // 1608),
        settings: {network: "tcp,udp", followRedirect: true},
        streamSettings: {sockopt: {tproxy: "tproxy"}},
        sniffing: {
            enabled: true,
            # "fakedns" is what turns a fake address back into the name it
            # stands for. Without it a faked destination reaches the rules as
            # an address from a reserved range and matches nothing.
            destOverride: (
                ["http", "tls", "quic"]
                + (if (settings.dns_mode // "off") == "fakeip" then ["fakedns"] else [] end)
            ),
            routeOnly: true
        }
    };

def profile_domains($profile):
    ([ $profile.community_list[]? | "geosite:\(.)" ] + [ $profile.domain[]? ])
    | map(select(. != null and . != ""));

def profile_ips($profile):
    [ $profile.subnet[]? ] | map(select(. != null and . != ""));

def fakeip_enabled: (settings.dns_mode // "off") == "fakeip";

# Client queries arrive here after dnsmasq is pointed at this address. It is a
# plain listener: what to answer is decided by the dns section, not here.
def dns_inbound:
    {
        tag: "dns-in",
        protocol: "dokodemo-door",
        listen: (settings.dns_address // "127.0.0.43"),
        port: (settings.dns_port // 53),
        settings: {address: "127.0.0.1", port: 53, network: "tcp,udp"}
    };

def inbounds_section:
    [ tproxy_inbound, probe_inbound ]
    + (if fakeip_enabled then [ dns_inbound ] else [] end);

# Domains that are routed through a channel rather than straight out. Only
# these get a fake address: faking everything would hand a fake answer to
# traffic that was going direct anyway, and anything not passing through the
# engine - the router's own requests, for instance - would be left holding an
# address that leads nowhere.
def routed_domains:
    [
        .bindings[]?
        | select((.channel.type // "direct") != "direct")
        | profile_domains(.profile)[]
    ];

# The resolver address as the engine wants it.
#
# dns_type existed in the configuration and in the interface, and nothing read
# it: whatever was chosen, the address went to the engine as typed. A setting
# that does nothing is worse than a missing one - it is believed.
#
# A scheme already typed by hand wins: someone who wrote "https+local://..."
# means it, and second-guessing that would silently change what they asked for.
def resolver_address($raw):
    ($raw // "8.8.8.8") as $s
    | (settings.dns_type // "doh") as $t
    | if ($s | index("://")) != null then $s
      elif $t == "udp" then $s
      elif $t == "tcp" then "tcp://" + $s
      elif $t == "dot" then "tls://" + $s
      elif $t == "quic" then "quic://" + $s
      else "https://" + (if ($s | index("/")) != null then $s else $s + "/dns-query" end)
      end;

# Четыре числа через точку и ничего кроме. Записано без регулярных выражений
# намеренно: jq в OpenWrt собран без oniguruma, и test/match там не существует
# вовсе - программа с ними падает на роутере, пройдя все проверки здесь.
def is_ipv4($s):
    ($s | split("."))
    | length == 4
    and all(.[]; (. != "") and (explode | all(. >= 48 and . <= 57)));

# Имена, которые подделывать нельзя ни при каких условиях.
#
# FakeDNS в Xray отвечает на всё, что до него дошло: фильтр по доменам у него
# в списке серверов не работает - проверено на живом движке, подделка досталась
# и example.com, и ya.ru при указанном одном домене. Единственный способ
# оставить имя настоящим - перечислить его РАНЬШЕ подделки.
#
# Что обязано остаться настоящим:
#
#   - адрес пробы. Наблюдатель ходит по нему мимо маршрутизации, прямо через
#     узел, и с поддельным адресом проба не проходит никогда. На роутере это
#     выглядело так: туннель работает, а все узлы числятся мёртвыми;
#   - имена самих серверов подписки. Движку надо соединиться с ними, и если
#     имя подделано, соединяться не с чем вовсе;
#   - имя резолвера, если оно задано именем.
def dns_real_domains:
    (
        [ settings.probe_url // "https://connectivitycheck.gstatic.com/generate_204" ]
        | map(
            (. | split("//") | last | split("/") | first | split(":") | first)
            | select(. != null and . != "")
            | "domain:" + .
          )
    )
    + [ .pool[]?.outbound
        | (.settings.vnext[0].address? // .settings.servers[0].address? // .settings.address?)
        | select(. != null and . != "")
        | select((is_ipv4(.) | not))
        | "domain:" + .
      ]
    + (
        (settings.dns_server // "") as $s
        | ($s | split("//") | last | split("/") | first | split(":") | first) as $host
        | if $host == "" or is_ipv4($host) then [] else [ "domain:" + $host ] end
      )
    | unique;

def dns_servers:
    resolver_address(settings.dns_server) as $primary
    | (settings.canary_learned // []) as $learned
    | (settings.dns_bootstrap // "") as $bootstrap
    # Исключения идут первыми, иначе подделка заберёт их себе.
    | (if fakeip_enabled and ((dns_real_domains | length) > 0) then
        [ {address: $primary, domains: dns_real_domains} ]
       else [] end)
    + (if fakeip_enabled and ((routed_domains | length) > 0) then
        [ {address: "fakedns", domains: routed_domains} ]
       else [] end)
    # Отбраковка выученного ставится на КАЖДЫЙ сервер группы, а не только
    # на первый.
    #
    # Это и есть режим локального резолвера из docs/dns.md: AdGuard Home или
    # Pi-hole стоит рядом с шифрованным, заданным IP-литералом, и пока всё
    # честно - отвечает тот, кто быстрее, обычно локальный, и фильтрация
    # работает. Когда провайдер перехватывает апстрим локального, сам он жив
    # и отвечает - проверкой доступности это не поймать вовсе, - но в ответах
    # появляется заглушка. Без unexpectedIPs на локальном сервере такой ответ
    # проходит насквозь, и роутер уверенно раздаёт подменённые адреса.
    #
    # Соседние серверы движок считает одной группой, когда у них совпадают
    # domains, expectedIPs и unexpectedIPs, - поэтому одинаковый список здесь
    # не только правилен по смыслу, но и держит группу целой.
    + [ ({address: $primary}
         + (if ($learned | length) > 0 then {unexpectedIPs: $learned} else {} end)) ]
    + [ settings.dns_extra[]?
        | ({address: .}
           + (if ($learned | length) > 0 then {unexpectedIPs: $learned} else {} end)) ]
    # Опорный резолвер нужен ровно в одном случае: основной задан именем,
    # и это имя надо где-то разрешить. Движок берёт для этого другой сервер
    # из списка, поэтому опорный и добавляется сюда - последним, чтобы он
    # отвечал только на то, на что не ответил основной. Когда основной задан
    # адресом, разрешать нечего, и лишний резолвер только путал бы.
    + (if $bootstrap != "" and (is_ipv4(settings.dns_server // "") | not)
       then [ {address: $bootstrap} ] else [] end);

def dns_section:
    {
        # IPv4 only for now: a fake address pool is IPv4, and answering AAAA
        # for a name that will be faked sends the client out over a path the
        # rules do not cover.
        queryStrategy: (settings.query_strategy // "UseIPv4"),
        # Параллельный опрос: либо его попросили явно, либо резолверов больше
        # одного и спрашивать их по очереди значит ждать самый медленный.
        enableParallelQuery: (
            ((settings.dns_parallel // "0") == "1")
            or (((settings.dns_extra // []) | length) > 0)
        ),

        # Кэш ответов.
        #
        # По умолчанию он нужен: без него каждое имя спрашивается заново,
        # а на задушенном DoH это видно как «интернет думает». Но бывает
        # обратное: имя живёт на двух CDN сразу, ответы чередуются, и один
        # из них у провайдера не работает. Тогда закреплённый ответ делает
        # сайт мёртвым до конца TTL, а без кэша следующая попытка попадает
        # на живой адрес.
        #
        # Ключ проверен самим движком; поля переписи TTL, как rewrite_ttl
        # у sing-box, в Xray нет вовсе - есть только это.
        disableCache: ((settings.dns_cache // "1") == "0"),

        # Подсказка о том, откуда спрашивают.
        #
        # Без неё резолвер решает по собственному расположению, а не по нашему,
        # и CDN выдаёт узел не той страны. На живом роутере это видно прямо:
        # обычным UDP Apple отвечает то одним CDN, то другим, а по DoH почти
        # всегда дальним. Адрес берётся из настроек и не угадывается: назвать
        # тут внутренний адрес роутера хуже, чем не назвать ничего.
        clientIp: (
            if (settings.dns_client_ip // "") == "" then null
            else settings.dns_client_ip end
        ),
        servers: dns_servers
    } | with_entries(select(.value != null));

# Service outbounds, always present and always named the same: the stats
# command derives traffic roles from these tags, and a rename here silently
# moves traffic into the wrong column of the dashboard.
# Интерфейс наружу задаётся только когда его назвали. По умолчанию решает
# таблица маршрутизации роутера, и это правильное поведение: привязка к имени
# интерфейса ломается ровно там, где его переименовали или где их два.
# Метка на собственные исходящие сокеты движка.
#
# Она и разрывает петлю: правила nft пропускают помеченный ею трафик, вместо
# того чтобы заворачивать его обратно в движок. Ставится на каждый исходящий,
# включая пришедшие из подписки, и аккуратно подмешивается к их собственным
# streamSettings, а не затирает их.
def engine_mark: (settings.engine_mark // 4194304);

def with_engine_mark($o):
    ($o.streamSettings // {}) as $ss
    | $o + {
        streamSettings: ($ss + {sockopt: (($ss.sockopt // {}) + {mark: engine_mark})})
      };

def output_sockopt:
    (settings.output_interface // "")
    | if . == "" then {} else {sockopt: {interface: .}} end;

# Как прямой исходящий выбирает адрес назначения.
#
# "UseIP" заставляет движок разрешить имя заново перед каждым новым прямым
# соединением - при том, что адрес уже известен: его разрешил клиент, а tproxy
# принёс вместе с пакетом. Лишний запрос ничего не даёт и всё портит: пока наш
# резолвер отвечает медленно или не отвечает вовсе - а DoH к публичным
# резолверам душат ровно там, где этот роутер и нужен, - каждое прямое
# соединение ждёт таймаута. Внешне это выглядит как "интернет тормозит",
# и причина не называется нигде.
#
# "AsIs" берёт адрес, который пришёл с пакетом. Исключение - режим поддельных
# адресов: там пришедший адрес поддельный и разрешать его обязательно.
def direct_domain_strategy:
    if fakeip_enabled then "UseIP" else "AsIs" end;

def service_outbounds:
    [
        ({tag: service_tags.direct, protocol: "freedom",
          settings: {domainStrategy: direct_domain_strategy}}
         + (if (output_sockopt | length) > 0 then {streamSettings: output_sockopt} else {} end)),
        {tag: service_tags.block, protocol: "blackhole"}
    ]
    + (if fakeip_enabled then [ {tag: service_tags.dns, protocol: "dns"} ] else [] end);

def node_outbounds:
    [ .pool[]? | .outbound ];

# Blackhole никуда не соединяется, и streamSettings ему не нужны: метка
# ставится всем, кто действительно ходит наружу.
def outbounds_section:
    [ (service_outbounds + node_outbounds)[]
      | if .protocol == "blackhole" then . else with_engine_mark(.) end ];

# One balancer over the whole pool. The engine excludes nodes the observatory
# calls dead by itself, so quarantine is native and ours only to display.
# Как выбирается узел.
#
# leastPing берёт наименьшую задержку и ничего не знает про то, что было
# секунду назад: два узла с близкими значениями меняются местами от шума
# измерения, и выбор скачет без всякой пользы. Прямого «не переключайся, пока
# разница меньше стольких-то миллисекунд» у движка нет - в sing-box это
# tolerance у urltest, здесь такого поля не существует.
#
# Что есть - пороги у leastLoad: узлы быстрее первого порога считаются равными,
# и мелкая разница между ними перестаёт что-либо решать. expected: 1 оставляет
# один узел, чтобы соединения не размазывались по всей группе.
#
# Формы проверены на самом движке: он принимает и baselines, и maxRTT,
# и tolerance, но смысл им придаёт только leastLoad.
def balancer_strategy:
    (settings.strategy // "leastLoad") as $type
    | if $type == "leastLoad" then
        {
            type: "leastLoad",
            settings: {
                baselines: (settings.strategy_baselines // ["300ms", "600ms", "1s"]),
                expected: 1
            }
        }
      else
        {type: $type}
      end;

def balancers_section:
    node_tags as $tags
    | if ($tags | length) == 0 then
        []
      else
        [{
            tag: "pool",
            selector: $tags,
            strategy: balancer_strategy,
            fallbackTag: service_tags.direct
        }]
      end;

# Health checks that feed both the balancer and the node states of "xkop
# stats". Durations are strings on purpose: the engine parses "30s" and refuses
# a number outright.
def observatory_section:
    node_tags as $tags
    | if ($tags | length) == 0 then
        null
      else
        {
            subjectSelector: $tags,
            pingConfig: {
                destination: (settings.probe_url // "https://connectivitycheck.gstatic.com/generate_204"),
                interval: (settings.probe_interval // "3m"),
                timeout: "5s",
                sampling: 3
            }
        }
      end;

# Источники, чей трафик уходит в туннель целиком, независимо от списков.
#
# Правило по источнику, а не по назначению: адрес клиента переживает перехват
# tproxy, поэтому движок его видит и может по нему решать. Стоит выше правил
# привязок - иначе список доменов успел бы отправить часть трафика напрямую,
# и "целиком" перестало бы быть целиком. Но ниже правила локальных сетей:
# устройство, которому велено ходить через туннель, всё равно должно
# дотягиваться до соседа по локальной сети и до самого роутера.
def fully_routed_rules($has_pool):
    (settings.fully_routed_ip // []) as $ips
    | if ($ips | length) == 0 then
        []
      else
        [ {type: "field", source: $ips}
          + (if $has_pool then {balancerTag: "pool"}
             else {outboundTag: service_tags.direct} end) ]
      end;

# A binding becomes at most two rules: one for names, one for addresses. An
# empty profile produces nothing at all rather than a rule that matches
# everything - which is the difference between "nothing is routed" and
# "everything is".
def binding_rules($binding; $has_pool):
    ($binding.channel.type // "direct") as $type
    | (if $type == "block" then {outboundTag: service_tags.block}
       elif $type == "direct" then {outboundTag: service_tags.direct}
       elif $has_pool then {balancerTag: "pool"}
       else {outboundTag: service_tags.direct}
       end) as $target
    | profile_domains($binding.profile) as $domains
    | profile_ips($binding.profile) as $ips
    | [
        (if ($domains | length) > 0 then ({type: "field", domain: $domains} + $target) else empty end),
        (if ($ips | length) > 0 then ({type: "field", ip: $ips} + $target) else empty end)
      ];

# Known public DoH resolvers. A client that resolves names on its own never
# reaches ours: no address of ours is handed out, the traffic quietly stops
# being routed, and the router looks perfectly healthy while doing it. The list
# is carried over from podkop, where it was assembled against real clients.
def doh_addresses: [
    "1.1.1.1", "1.0.0.1", "1.1.1.2", "1.0.0.2", "1.1.1.3", "1.0.0.3",
    "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
    "94.140.14.14", "94.140.15.15", "208.67.222.222", "208.67.220.220",
    "45.90.28.0/24", "45.90.30.0/24", "194.242.2.2",
    "76.76.2.0/24", "76.76.10.0/24"
];

# Deliberately off unless asked for. A client with its own resolver on some
# arbitrary address slips through anyway, and blocking the well known ones
# breaks whoever was using them on purpose.
def protection_rules:
    (if (settings.block_client_doh // "0") == "1" then
        [
            # Port 853 carries nothing but DNS - DoT and DoQ both - so the
            # whole port can go. This is what catches Android's private DNS.
            {type: "field", port: 853, outboundTag: service_tags.block},
            {type: "field", ip: doh_addresses, port: 443, outboundTag: service_tags.block}
        ]
     else [] end)
    + (if (settings.disable_quic // "0") == "1" then
        [ {type: "field", protocol: ["quic"], outboundTag: service_tags.block} ]
       else [] end);

def routing_section:
    (node_tags | length > 0) as $has_pool
    | {
        domainStrategy: "IPIfNonMatch",
        rules: (
            (if fakeip_enabled then
                # Everything arriving at the DNS listener is answered by the
                # engine's own resolver. First rule, because a query must never
                # fall through to the routing below and leave as traffic.
                [ {type: "field", inboundTag: ["dns-in"], outboundTag: service_tags.dns} ]
             else [] end)
            + protection_rules
            +
            [
                # Anything aimed at the local network stays local. Written out
                # rather than as "geoip:private" on purpose: that spelling pulls
                # in geoip.dat, ten megabytes of flash for a list of ranges
                # everyone already knows.
                {type: "field", outboundTag: service_tags.direct, ip: [
                    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
                    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
                    "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
                    "::1/128", "fc00::/7", "fe80::/10"
                ]}
            ]
            + fully_routed_rules($has_pool)
            + ( [ .bindings[]? ] | sort_by(.order // 100)
                | map(binding_rules(.; $has_pool)) | add // [] )
        ),
        balancers: balancers_section
    };

# Bound before the object is built: past the pipe "." is the configuration
# being assembled, not the input, and anything reading .pool there quietly
# returns nothing. Every balancer requires an observatory feature - without it
# the engine refuses the whole configuration with "not all dependencies are
# resolved", which is a dead router.
observatory_section as $observatory
| fakeip_enabled as $fakeip
| dns_section as $dns
| (settings.fakeip_range // "198.18.0.0/15") as $fakeip_range
| {
    log: log_section,
    stats: stats_section,
    policy: policy_section,
    metrics: metrics_section,
    api: api_section,
    inbounds: inbounds_section,
    outbounds: outbounds_section,
    routing: routing_section
}
| if $observatory != null then . + {burstObservatory: $observatory} else . end
| if $fakeip then
    . + {dns: $dns, fakedns: {ipPool: $fakeip_range, poolSize: 65535}}
  else . end
