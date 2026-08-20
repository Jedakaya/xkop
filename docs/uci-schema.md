# Схема UCI

Это граница между четырьмя компонентами: бэкендом, LuCI, клиентской панелью
и скриптом первичной настройки. Всё, что внутри компонента, переделывается
дёшево; всё, что здесь, — дорого. Поэтому фиксируется до кода.

Файл: `/etc/config/xkop`

## Пять типов секций

```
config settings 'settings'      системные настройки, одна на роутер
config subscription '<id>'      источник серверов
config channel '<id>'           куда направить трафик
config profile '<id>'           что направить
config binding '<id>'           профиль -> канал
```

Модель заменяет матрицу podkop `connection_type` на `proxy_config_type`,
где часть сочетаний невалидна, а одно роняло запуск.

## settings

```
config settings 'settings'
    # DNS
    option dns_type              'doh'          udp | doh | dot
    option dns_server            '8.8.8.8/dns-query'
    option dns_bootstrap         '77.88.8.8'
    option dns_rewrite_ttl       '60'
    option dns_parallel          '1'            опрос нескольких серверов сразу
    list   dns_extra_server      'dot:1.1.1.1'  дополнительные для параллели

    # Канарейка
    option canary_enabled        '1'
    option canary_interval       '2m'
    list   canary_learned_ip     '46.191.166.9' выученные заглушки, пишется само

    # Отказоустойчивость DNS
    option dns_failover          '1'
    option dns_failover_on_local '0'            уходить в обход AGH при перехвате

    # Защита от обхода клиентами
    option block_client_doh      '0'            443 к известным DoH и весь 853

    # Сеть
    list   source_interface      'br-lan'
    option output_interface      ''             пусто = автоопределение
    list   excluded_source_ip    ''             не маршрутизировать этот источник

    # Служебное
    option lists_update_interval '1d'
    option log_level             'warn'
    option metrics_port          '11111'
    option dont_touch_dhcp       '0'
    option exclude_ntp           '0'
    option disable_quic          '0'
```

## subscription

Самостоятельная сущность: своя ссылка, свои UA, своё расписание, свой кэш.
Каналы на неё ссылаются.

```
config subscription 'main'
    option enabled          '1'
    option url              'https://example.com/api/sub'
    list   user_agent       'Happ/4.10.2/ios/2605221402666'
    list   user_agent       'v2rayN/9.99'
    option update_interval  '1h'
    option include          ''       ключевые слова, оставить только
    option exclude          'info'   ключевые слова, исключить
```

Несколько `user_agent` — не выбор одного из, а **слияние**: разные UA дают
дополняющие наборы серверов, см. `subscription.md`.

Состояние подписки в UCI не хранится — оно в кэше на диске.

## channel

```
config channel 'tunnel'
    option type           'subscription'   subscription | link | wireguard | direct | block
    list   subscription   'main'           можно несколько -> общий пул
    option selection      'auto'           auto | manual
    option strategy       'leastPing'      leastPing | leastLoad | roundRobin
    option probe_url      'https://www.gstatic.com/generate_204'
    option probe_interval '3m'
    option active         ''               при manual — тег выбранного узла

config channel 'direct'
    option type 'direct'

config channel 'blocked'
    option type 'block'
```

Каналы `direct` и `blocked` существуют всегда и не удаляются.

## profile

Что направляем. Намерение, а не перечень реализаций.

```
config profile 'blocked_ru'
    option title            'Заблокированное в РФ'
    list   community_list   'russia_inside'
    list   community_list   'geoblock'
    list   domain           'example.com'
    list   subnet           '203.0.113.0/24'
    list   remote_domains   'https://example.com/domains.lst'
    list   remote_subnets   'https://example.com/subnets.lst'
    list   local_domains    '/etc/xkop/my-domains.lst'
    list   local_subnets    '/etc/xkop/my-subnets.lst'
```

## binding

Маршрутизация целиком: несколько строк вместо двух секций по три десятка
опций.

```
config binding 'b1'
    option profile  'blocked_ru'
    option channel  'tunnel'
    option order    '10'

config binding 'b2'
    option profile  'ads'
    option channel  'blocked'
    option order    '20'
```

`order` определяет приоритет при пересечении профилей: меньше — раньше.
Источники, попадающие целиком в канал, задаются профилем с `source` вместо
списков доменов.

## Инварианты схемы

**Отсутствие подписки не фатально.** Канал без пригодной подписки неактивен,
привязки на него игнорируются, запуск продолжается. В podkop пустая ссылка
завершала старт до установки задач по расписанию.

**Ссылки проверяются, а не подразумеваются.** Привязка на несуществующий
профиль или канал — предупреждение в лог и пропуск, не отказ.

**Состояние не хранится в конфигурации.** Выученные Канарейкой адреса —
исключение, они нужны между перезагрузками; всё остальное живёт в кэше.

## Соответствие podkop

Для проверки, что ничего не осиротело — см. `feature-inventory.md`.

| podkop | xkop |
|---|---|
| `connection_type` + `proxy_config_type` | `channel.type` |
| `subscription_url` в секции | отдельная секция `subscription` |
| `community_lists` в секции | `profile.community_list` |
| `urltest_*` | `channel.strategy` + `probe_*` |
| `fully_routed_ips` | профиль с `source` |
| `routing_excluded_ips` | `settings.excluded_source_ip` |
| `dns_failover_on_local` | без изменений |
