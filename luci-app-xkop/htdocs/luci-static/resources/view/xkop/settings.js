"use strict";
"require form";
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

  o = s.option(form.DynamicList, "community_list", _("Списки сообщества"),
    _("Категории из geosite: russia-inside, geoblock, block, youtube, discord, meta, news, porn, hdrezka, anime."));
  o.value("russia-inside");
  o.value("geoblock");
  o.value("block");
  o.value("youtube");
  o.value("discord");
  o.value("meta");
  o.value("news");
  o.value("porn");
  o.value("hdrezka");
  o.value("anime");
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

function bindings(map) {
  const s = map.section(form.TypedSection, "binding", _("Привязки"),
    _("Профиль в канал. Это и есть маршрутизация."));
  s.anonymous = false;
  s.addremove = true;
  s.addbtntitle = _("Добавить привязку");

  let o = s.option(form.Value, "profile", _("Профиль"));
  o = s.option(form.Value, "channel", _("Канал"));

  o = s.option(form.Value, "order", _("Порядок"),
    _("Меньше — раньше. Решает, чей профиль победит при пересечении."));
  o.datatype = "uinteger";
  o.default = "100";
}

function system(map) {
  const s = map.section(form.NamedSection, "settings", "settings", _("Система"));
  s.anonymous = true;
  s.addremove = false;

  let o = s.option(form.ListValue, "dns_mode", _("Режим DNS"),
    _("«Не трогать» — имена движок узнаёт по самому соединению, dnsmasq остаётся как был. «Поддельные адреса» — движок отвечает сам."));
  o.value("off", _("не трогать"));
  o.value("fakeip", _("поддельные адреса"));
  o.default = "off";

  o = s.option(form.Value, "dns_server", _("Резолвер"),
    _("Задавать адресом, а не именем: имя требует разрешения по тому самому порту 53, который и перехватывают."));
  o.default = "8.8.8.8/dns-query";
  o.depends("dns_mode", "fakeip");

  o = s.option(form.DynamicList, "dns_extra_server", _("Дополнительные резолверы"),
    _("Опрашиваются одновременно, берётся первый ответ."));
  o.optional = true;
  o.depends("dns_mode", "fakeip");

  o = s.option(form.Flag, "canary_enabled", _("Канарейка"),
    _("Обнаружение подмены DNS провайдером. Выученные заглушки движок отбраковывает сам."));
  o.default = "1";

  o = s.option(form.DynamicList, "source_interface", _("Интерфейсы источника"),
    _("С каких интерфейсов брать трафик клиентов."));
  o.default = "br-lan";
  o.datatype = "string";

  o = s.option(form.DynamicList, "excluded_source_ip", _("Исключённые адреса"),
    _("Эти источники не маршрутизируются вовсе."));
  o.optional = true;

  o = s.option(form.Flag, "access_log", _("Журнал доступа"),
    _("Строка на соединение с выбранным исходящим. На нём держится разбор маршрута."));
  o.default = "1";

  // Реже нужное — ниже. Клиент со своим резолвером на произвольном адресе
  // под эти правила всё равно не попадёт, поэтому по умолчанию выключено.
  o = s.option(form.Flag, "block_client_doh", _("Блокировать известные DoH"),
    _("Порт 853 целиком и известные публичные DoH на 443."));
  o.default = "0";

  o = s.option(form.Flag, "block_https_records", _("Отклонять записи HTTPS"),
    _("Ломает автообнаружение DoH браузерами."));
  o.default = "0";

  o = s.option(form.Flag, "block_ptr_records", _("Отклонять PTR"),
    _("Иначе mDNS от устройств Apple даёт задержки в десятки секунд."));
  o.default = "0";

  o = s.option(form.Flag, "block_firefox_canary", _("Отклонять канарейку Firefox"));
  o.default = "0";

  o = s.option(form.Flag, "disable_quic", _("Отключить QUIC"));
  o.default = "0";

  o = s.option(form.Flag, "dont_touch_dhcp", _("Не трогать dnsmasq"),
    _("Если резолвер настроен вручную и трогать его нельзя."));
  o.default = "0";

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
    system(map);
  },
});
