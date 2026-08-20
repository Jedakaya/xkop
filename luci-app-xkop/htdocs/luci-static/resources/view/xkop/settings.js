"use strict";
"require form";
"require uci";
"require network";

// Настройки.
//
// Вместо матрицы «тип соединения на тип конфигурации», где часть сочетаний
// невалидна, а одно роняет запуск, — три сущности: каналы, профили
// и привязки. Маршрутизация умещается в таблицу из нескольких строк.
//
// Уровни видимости: обычное впереди, редкое под спойлером. Роутер настраивают
// раз в жизни, а смотрят на него часто.

function subscriptions(map) {
  const s = map.section(form.TypedSection, "subscription", _("Подписки"),
    _("Своя ссылка, свои агенты, своё расписание. Каналы ссылаются на подписку, а не наоборот."));
  s.anonymous = false;
  s.addremove = true;
  s.addbtntitle = _("Добавить подписку");

  let o = s.option(form.Flag, "enabled", _("Включена"));
  o.default = "1";
  o.rmempty = false;

  o = s.option(form.Value, "url", _("Ссылка"),
    _("Формат выбирается путём: к ссылке пробуются /json и /v2ray-json, и только потом сама ссылка."));
  o.placeholder = "https://example.com/api/sub";

  o = s.option(form.Value, "update_interval", _("Интервал обновления"));
  o.default = "1h";
  o.placeholder = "1h";

  o = s.option(form.DynamicList, "user_agent", _("Дополнительные User-Agent"),
    _("Обычно не нужны: xkop представляется своим именем. Заполняется, если панель отдаёт разное разным клиентам."));
  o.optional = true;

  o = s.option(form.Value, "include", _("Оставить только"),
    _("Ключевые слова в имени сервера, через пробел."));
  o.optional = true;

  o = s.option(form.Value, "exclude", _("Исключить"),
    _("Ключевые слова в имени сервера, через пробел."));
  o.optional = true;
}

function channels(map) {
  const s = map.section(form.TypedSection, "channel", _("Каналы"),
    _("Куда можно направить трафик. Канал самодостаточен."));
  s.anonymous = false;
  s.addremove = true;
  s.addbtntitle = _("Добавить канал");

  let o = s.option(form.ListValue, "type", _("Тип"));
  o.value("subscription", _("подписка"));
  o.value("direct", _("напрямую"));
  o.value("block", _("блокировать"));
  o.default = "subscription";

  o = s.option(form.DynamicList, "subscription", _("Подписки"),
    _("Можно несколько — тогда серверы сливаются в общий пул."));
  uci.sections("xkop", "subscription", function (sec) {
    o.value(sec[".name"], sec[".name"] + (sec.url ? "" : " — " + _("ссылка не задана")));
  });
  o.depends("type", "subscription");
  o.optional = true;

  o = s.option(form.ListValue, "strategy", _("Выбор узла"));
  o.value("leastPing", _("по наименьшей задержке"));
  o.value("leastLoad", _("по наименьшей нагрузке"));
  o.value("roundRobin", _("по кругу"));
  o.value("random", _("случайно"));
  o.default = "leastPing";
  o.depends("type", "subscription");
}

function profiles(map) {
  const s = map.section(form.TypedSection, "profile", _("Профили"),
    _("Что направляем. Намерение, а не перечень: «заблокированное в РФ», «только эти домены»."));
  s.anonymous = false;
  s.addremove = true;
  s.addbtntitle = _("Добавить профиль");

  let o = s.option(form.Value, "title", _("Название"));
  o.placeholder = _("Заблокированное в РФ");

  // Перечень выдран из самого geosite.dat релиза allow-domains, а не выписан
  // по памяти: категория, которой в файле нет, молча не сработает, и профиль
  // будет выглядеть настроенным, ничего не направляя.
  o = s.option(form.DynamicList, "community_list", _("Списки сообщества"),
    _("Категории из geosite. Источник: itdoginfo/allow-domains."));
  [
    ["russia-inside", _("Россия, внутренние")],
    ["russia-outside", _("Россия, внешние")],
    ["ukraine-inside", _("Украина")],
    ["geoblock", _("Геоблокировки")],
    ["block", _("Заблокированное")],
    ["youtube", "YouTube"],
    ["discord", "Discord"],
    ["telegram", "Telegram"],
    ["twitter", "Twitter (X)"],
    ["meta", "Meta"],
    ["tiktok", "TikTok"],
    ["roblox", "Roblox"],
    ["google-ai", "Google AI"],
    ["google-play", "Google Play"],
    ["google-meet", "Google Meet"],
    ["hdrezka", "HDRezka"],
    ["anime", _("Аниме")],
    ["news", _("Новости")],
    ["porn", _("Взрослое")],
    ["hodca", "H.O.D.C.A"],
    ["hetzner", _("Hetzner, сети")],
    ["ovh", _("OVH, сети")],
    ["digitalocean", _("DigitalOcean, сети")],
  ].forEach(function (pair) {
    o.value(pair[0], pair[1]);
  });
  o.optional = true;

  o = s.option(form.DynamicList, "domain", _("Свои домены"));
  o.optional = true;

  o = s.option(form.DynamicList, "subnet", _("Свои подсети"));
  o.optional = true;
  o.placeholder = "203.0.113.0/24";

  o = s.option(form.DynamicList, "remote_domains", _("Списки доменов по ссылке"));
  o.optional = true;

  o = s.option(form.DynamicList, "remote_subnets", _("Списки подсетей по ссылке"));
  o.optional = true;

  o = s.option(form.DynamicList, "local_domains", _("Списки доменов из файла"));
  o.optional = true;
  o.placeholder = "/etc/xkop/my-domains.lst";

  o = s.option(form.DynamicList, "local_subnets", _("Списки подсетей из файла"));
  o.optional = true;
}

// Привязка отвечает на один вопрос: что куда направить. Поэтому и профиль,
// и канал — списки уже заведённого, а не поля, где надо вспомнить имя секции.
function bindings(map) {
  const s = map.section(form.TypedSection, "binding", _("Привязки"),
    _("Что куда направить: профиль (какие домены) в канал (каким путём). Из этих строк и складывается маршрутизация."));
  s.anonymous = false;
  s.addremove = true;
  s.addbtntitle = _("Добавить привязку");

  let o = s.option(form.ListValue, "profile", _("Что направляем"),
    _("Профиль со списками доменов и подсетей."));
  uci.sections("xkop", "profile", function (sec) {
    o.value(sec[".name"], (sec.title || sec[".name"]) + " (" + sec[".name"] + ")");
  });

  o = s.option(form.ListValue, "channel", _("Куда направляем"),
    _("Канал: подписка, напрямую или блокировать."));
  const channelTitles = {
    subscription: _("через подписку"),
    direct: _("напрямую"),
    block: _("блокировать"),
  };
  uci.sections("xkop", "channel", function (sec) {
    const kind = channelTitles[sec.type] || sec.type || "";
    o.value(sec[".name"], sec[".name"] + (kind ? " — " + kind : ""));
  });

  o = s.option(form.Value, "order", _("Порядок"),
    _("Меньше — раньше. Решает, чей профиль победит, если домен попал сразу в два."));
  o.datatype = "uinteger";
  o.default = "100";
}

// DNS — своя вкладка, а не три строки среди пятнадцати флажков.
//
// Раньше режим DNS, резолвер и защита лежали во «Системе» вперемешку
// с интерфейсами и журналом. Настройка, которую невозможно найти, ничем
// не отличается от отсутствующей.
function dns(map) {
  const s = map.section(form.NamedSection, "settings", "dns", _("DNS"));
  s.anonymous = true;
  s.addremove = false;

  let o = s.option(form.ListValue, "dns_mode", _("Режим"),
    _("«Не трогать» — имена движок узнаёт по самому соединению, dnsmasq остаётся как был. «Поддельные адреса» — движок отвечает сам, и dnsmasq переключается на него."));
  o.value("off", _("не трогать (по имени в соединении)"));
  o.value("fakeip", _("поддельные адреса (FakeIP)"));
  o.default = "off";

  o = s.option(form.ListValue, "dns_type", _("Как спрашивать"),
    _("Способ обращения к резолверу."));
  o.value("doh", _("DoH, по HTTPS"));
  o.value("dot", _("DoT, по TLS"));
  o.value("udp", _("обычный UDP"));
  o.default = "doh";
  o.depends("dns_mode", "fakeip");

  // Список с возможностью вписать своё: form.Value с вариантами — это
  // выпадающий список, который не запрещает ввод. Схему подставляет генератор
  // по выбранному способу, поэтому здесь чистый адрес.
  o = s.option(form.Value, "dns_server", _("Резолвер"),
    _("Адрес предпочтительнее имени: имя надо где-то разрешить, а порт 53 как раз и перехватывают."));
  [
    ["8.8.8.8", "8.8.8.8 (Google)"],
    ["8.8.4.4", "8.8.4.4 (Google)"],
    ["1.1.1.1", "1.1.1.1 (Cloudflare)"],
    ["1.0.0.1", "1.0.0.1 (Cloudflare)"],
    ["9.9.9.9", "9.9.9.9 (Quad9)"],
    ["dns.adguard-dns.com", "AdGuard, обычный"],
    ["unfiltered.adguard-dns.com", "AdGuard, без фильтров"],
    ["family.adguard-dns.com", "AdGuard, семейный"],
  ].forEach(function (pair) { o.value(pair[0], pair[1]); });
  o.default = "8.8.8.8";
  o.depends("dns_mode", "fakeip");

  o = s.option(form.Value, "dns_bootstrap", _("Опорный резолвер"),
    _("Нужен, только если основной задан именем: им это имя и разрешается."));
  [
    ["77.88.8.8", "77.88.8.8 (Яндекс)"],
    ["77.88.8.1", "77.88.8.1 (Яндекс)"],
    ["1.1.1.1", "1.1.1.1 (Cloudflare)"],
    ["8.8.8.8", "8.8.8.8 (Google)"],
    ["9.9.9.9", "9.9.9.9 (Quad9)"],
  ].forEach(function (pair) { o.value(pair[0], pair[1]); });
  o.default = "77.88.8.8";
  o.optional = true;
  o.depends("dns_mode", "fakeip");

  o = s.option(form.DynamicList, "dns_extra_server", _("Дополнительные резолверы"),
    _("Опрашиваются одновременно, берётся первый ответ."));
  o.optional = true;
  o.depends("dns_mode", "fakeip");

  o = s.option(form.Flag, "dns_failover", _("Запасной путь"),
    _("Если резолвер не отвечает, спросить обычным способом, а не остаться без имён."));
  o.default = "1";
  o.depends("dns_mode", "fakeip");

  o = s.option(form.Flag, "canary_enabled", _("Канарейка"),
    _("Обнаружение подмены DNS провайдером: спрашивает то, чего не может существовать, и по ответу узнаёт адрес заглушки. Выученное движок отбраковывает сам."));
  o.default = "1";

  o = s.option(form.Value, "canary_interval", _("Как часто проверять"),
    _("Например 2m, 1h."));
  o.default = "2m";
  o.depends("canary_enabled", "1");

  o = s.option(form.Flag, "dont_touch_dhcp", _("Не трогать dnsmasq"),
    _("Если резолвер настроен вручную и трогать его нельзя."));
  o.default = "0";

  // Защита от обхода. Выключено по умолчанию не из осторожности, а потому
  // что каждое из этих правил что-то ломает, и ломает молча.
  o = s.option(form.Flag, "block_client_doh", _("Блокировать известные DoH"),
    _("Порт 853 целиком и известные публичные DoH на 443. Клиент со своим резолвером на произвольном адресе под это правило не попадёт."));
  o.default = "0";

  o = s.option(form.Flag, "block_https_records", _("Отклонять записи HTTPS"),
    _("Ломает автообнаружение DoH браузерами. Конфликтует с получением конфигурации ECH через DNS."));
  o.default = "0";

  o = s.option(form.Flag, "block_ptr_records", _("Отклонять PTR"),
    _("Иначе mDNS от устройств Apple даёт задержки в десятки секунд."));
  o.default = "0";

  o = s.option(form.Flag, "block_firefox_canary", _("Отклонять канарейку Firefox"),
    _("Firefox сам выключит свой DoH, увидев отказ."));
  o.default = "0";

  o = s.option(form.Flag, "disable_quic", _("Отключить QUIC"),
    _("QUIC несёт своё шифрование и обходит разбор имени."));
  o.default = "0";
}

function system(map) {
  const s = map.section(form.NamedSection, "settings", "system", _("Система"));
  s.anonymous = true;
  s.addremove = false;

  let o = s.option(form.DynamicList, "source_interface", _("Интерфейсы источника"),
    _("С каких интерфейсов брать трафик клиентов."));
  o.default = "br-lan";
  o.datatype = "string";

  o = s.option(form.Value, "wan_interface", _("Интерфейс наружу"),
    _("Через него уходит трафик самого движка."));
  o.default = "wan";
  o.optional = true;

  o = s.option(form.DynamicList, "excluded_source_ip", _("Исключённые адреса"),
    _("Эти источники не маршрутизируются вовсе."));
  o.optional = true;

  o = s.option(form.Flag, "access_log", _("Журнал доступа"),
    _("Строка на соединение с выбранным исходящим. На нём держится разбор маршрута."));
  o.default = "1";

  o = s.option(form.Value, "lists_update_interval", _("Обновление списков"),
    _("Например 1d."));
  o.default = "1d";

  o = s.option(form.Flag, "exclude_ntp", _("Не трогать NTP"),
    _("Синхронизация времени идёт напрямую."));
  o.default = "0";

  o = s.option(form.Value, "metrics_port", _("Порт метрик"),
    _("Локальный эндпоинт движка, из которого берутся все числа обзора."));
  o.datatype = "port";
  o.default = "11111";

  o = s.option(form.ListValue, "log_level", _("Подробность журнала"));
  o.value("none", _("молчать"));
  o.value("error", _("ошибки"));
  o.value("warning", _("предупреждения"));
  o.value("info", _("подробно"));
  o.default = "warning";
}

return L.Class.extend({
  build: function (map) {
    subscriptions(map);
    channels(map);
    profiles(map);
    bindings(map);
    dns(map);
    system(map);
  },
});
