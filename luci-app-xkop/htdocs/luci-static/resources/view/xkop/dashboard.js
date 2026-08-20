"use strict";
"require ui";
"require poll";
"require view.xkop.api as api";

// Главный экран.
//
// Он отвечает не на вопрос «какой пинг у третьего сервера», а на вопрос
// «правильно ли сейчас распределяется трафик». Это и есть работа роутера,
// и именно её надо показывать — см. docs/dashboard.md.
//
// Три правила, купленные первым же показом на железе:
//
//   - один запуск команды на отрисовку. Было пять, и два из них ждали сеть;
//     страница открывалась секундами, а Канарейка вдобавок перезапускала
//     службу при изменении выученного. Открытие страницы не имеет права ни
//     ждать сеть, ни что-либо перезапускать;
//   - обновление на месте, а не перезагрузкой страницы. Перезагрузка после
//     каждой кнопки теряет и позицию прокрутки, и открытые списки;
//   - действие показывает, что стало, а не что мы просили сделать. «Служба
//     запущена» и «движок отвечает» — разные утверждения.

function line(label, value, hint) {
  return E("div", { class: "xkop-line" }, [
    E("span", { class: "xkop-label" }, label),
    E("span", { class: "xkop-value" }, value),
    hint ? E("span", { class: "xkop-hint" }, hint) : "",
  ]);
}

function card(title, children, extraClass) {
  return E("div", { class: "xkop-card " + (extraClass || "") }, [
    E("h3", {}, title),
    E("div", { class: "xkop-card-body" }, children),
  ]);
}

function widget(title, children) {
  return E("div", { class: "xkop-widget" }, [
    E("div", { class: "xkop-widget-title" }, title),
    E("div", { class: "xkop-widget-body" }, children),
  ]);
}

function big(value, unit) {
  return E("div", { class: "xkop-big" }, [
    E("span", {}, value),
    unit ? E("span", { class: "xkop-big-unit" }, " " + unit) : "",
  ]);
}

function kb(value) {
  return api.bytes((Number(value) || 0) * 1024);
}

// Одна строка сверху: работает, работает с оговорками, не работает. С
// причиной, а не с пятью зелёными галочками, которые пользователь должен
// истолковать сам.
function renderSummary(data) {
  const summary = (data && data.summary) || "состояние неизвестно";
  const good = summary === "работает";
  return E("div", { class: "xkop-summary " + (good ? "xkop-good" : "xkop-warn") }, [
    E("span", { class: "xkop-dot " + (good ? "xkop-dot-good" : "xkop-dot-warn") }, ""),
    E("span", {}, summary),
  ]);
}

// Первое, что нужно человеку, открывшему страницу: работает или нет, и чем
// это включить. Запустить роутер из интерфейса было нечем — только командой
// в консоли, о которой ещё надо знать.
function renderServiceWidget(data, refresh) {
  const svc = (data && data.service) || {};
  const eng = (data && data.engine) || {};
  const running = !!(svc.engine && svc.engine.running);

  function act(action, label, style) {
    return E("button", {
      class: "cbi-button " + style,
      click: ui.createHandlerFn(this, function () {
        return api.service(action).then(function (r) {
          if (!r || !r.ok) {
            ui.addNotification(null,
              E("p", {}, _("Не вышло: ") + ((r && r.error) || "?")), "error");
          } else {
            // Показывается то, что стало, а не то, что мы просили сделать.
            ui.addNotification(null, E("p", {}, _("Состояние: ") + (r.state || "?")),
              r.engine && r.engine.running ? "info" : "warning");
          }
          return refresh();
        });
      }),
    }, label);
  }

  const body = [
    big(running ? _("работает") : _("остановлен")),
    E("div", { class: "xkop-widget-note" }, svc.state || ""),
    line(_("движок"),
      eng.engine_installed ? "Xray " + (eng.engine_version || "?") : _("не установлен"),
      eng.engine_installed && eng.engine_version_ok === false ? _("версия ниже требуемой") : ""),
    line(_("автозапуск"), svc.enabled ? _("включён") : _("выключен"), ""),
  ];

  if (!eng.engine_installed) {
    body.push(E("div", { class: "xkop-warn-text" }, _("Без движка маршрутизировать нечем.")));
    body.push(E("div", { class: "xkop-note" },
      _("Поставить: xkop update, либо переустановить установщиком с GitHub.")));
  }

  body.push(E("div", { class: "xkop-controls" }, [
    running ? act("restart", _("Перезапустить"), "cbi-button-apply")
            : act("start", _("Запустить"), "cbi-button-apply"),
    running ? act("stop", _("Остановить"), "cbi-button-reset") : "",
    svc.enabled ? act("disable", _("Автозапуск выкл."), "cbi-button-neutral")
                : act("enable", _("Автозапуск вкл."), "cbi-button-neutral"),
  ]));

  return widget(_("Служба"), body);
}

// Распределение трафика числом: не обещание, а факт. Если через туннель ушло
// сто процентов, значит списки не применились, и это видно сразу, а не
// по жалобе клиента.
function renderTrafficWidget(stats) {
  if (!stats || !stats.ok || !stats.distribution) {
    return widget(_("Распределение"), E("div", { class: "xkop-empty" },
      stats && stats.error ? _("Метрики недоступны: ") + stats.error
                           : _("Метрики недоступны")));
  }

  const d = stats.distribution;
  const parts = [
    { key: "direct", label: _("напрямую"), css: "xkop-bar-direct", v: d.direct },
    { key: "proxy", label: _("туннель"), css: "xkop-bar-proxy", v: d.proxy },
    { key: "blocked", label: _("блок"), css: "xkop-bar-blocked", v: d.blocked },
  ];

  const any = parts.some(function (p) { return p.v && p.v.bytes > 0; });

  // Полоса вместо трёх процентов вразнобой: доля видна раньше, чем прочитана.
  const bar = E("div", { class: "xkop-bar" },
    any
      ? parts.map(function (p) {
          const share = (p.v && p.v.share) || 0;
          return E("div", {
            class: "xkop-bar-part " + p.css,
            style: "width:" + Math.max(0, share * 100) + "%",
            title: p.label + " " + api.percent(share),
          }, "");
        })
      : [E("div", { class: "xkop-bar-part xkop-bar-empty", style: "width:100%" }, "")]);

  const rows = parts.map(function (p) {
    return E("div", { class: "xkop-legend" }, [
      E("span", { class: "xkop-chip " + p.css }, ""),
      E("span", { class: "xkop-legend-label" }, p.label),
      E("span", { class: "xkop-legend-value" }, api.bytes((p.v && p.v.bytes) || 0)),
      E("span", { class: "xkop-legend-share" }, api.percent((p.v && p.v.share) || 0)),
    ]);
  });

  if (d.service && d.service.bytes > 0) {
    rows.push(E("div", { class: "xkop-legend xkop-legend-dim" }, [
      E("span", { class: "xkop-chip xkop-bar-service" }, ""),
      E("span", { class: "xkop-legend-label" }, _("служебное")),
      E("span", { class: "xkop-legend-value" }, api.bytes(d.service.bytes)),
      E("span", { class: "xkop-legend-share" }, api.percent(d.service.share)),
    ]));
  }

  if (!any) {
    rows.push(E("div", { class: "xkop-note" }, _("Трафика ещё не было.")));
  }

  return widget(_("Распределение"), [bar].concat(rows));
}

// Та же цифра с другой стороны: для владельца, платящего за серверы, это
// единственное число, имеющее денежное выражение.
function renderSavingsWidget(stats) {
  if (!stats || !stats.ok || !stats.distribution) {
    return widget(_("Всего"), E("div", { class: "xkop-empty" }, _("Нет данных")));
  }

  const total = stats.traffic && stats.traffic.outbound_total
    ? stats.traffic.outbound_total.total : 0;
  const tunnelled = stats.distribution.proxy ? stats.distribution.proxy.bytes : 0;
  const saved = Math.max(0, total - tunnelled);

  return widget(_("Всего"), [
    big(api.bytes(total)),
    E("div", { class: "xkop-widget-note" }, _("прошло через роутер")),
    line(_("мимо туннеля"), api.bytes(saved),
      total > 0 ? api.percent(saved / total) : ""),
    E("div", { class: "xkop-note" },
      _("Без распределения весь этот объём ушёл бы в туннель.")),
  ]);
}

function renderRouterWidget(data) {
  const sys = (data && data.system) || {};
  const r = sys.router || {};
  const st = sys.storage || {};

  return widget(_("Роутер"), [
    E("div", { class: "xkop-widget-note" }, r.model || _("модель неизвестна")),
    line(_("система"), r.release || "—", ""),
    line(_("архитектура"), r.arch || "—", r.package_manager || ""),
    line(_("xkop"), sys.xkop_version || data.version || "—", ""),
    line(_("флэш свободно"), kb(st.flash_free_kb),
      st.flash_total_kb ? _("из ") + kb(st.flash_total_kb) : ""),
    line(_("память свободно"), kb(st.memory_free_kb),
      st.memory_total_kb ? _("из ") + kb(st.memory_total_kb) : ""),
    sys.uptime ? line(_("работает"), sys.uptime, "") : "",
  ]);
}

// Пул серверов, а не список пингов. Число «7 из 9 живы» полезнее девяти
// чисел в миллисекундах; задержки раскрываются по требованию.
function renderPool(nodes, refresh) {
  if (!nodes || !nodes.ok) {
    return card(_("Пул серверов"), E("div", { class: "xkop-empty" }, _("Нет данных")));
  }

  const list = nodes.nodes || [];
  const alive = list.filter(function (n) { return n.state === "alive"; }).length;
  const pending = list.filter(function (n) { return n.state === "pending"; }).length;
  const dead = list.filter(function (n) { return n.state === "dead"; }).length;

  const head = [
    line(_("живых"), alive + _(" из ") + list.length,
      dead > 0 ? _("в карантине: ") + dead : ""),
  ];

  // Свежий узел до десяти минут не имеет данных наблюдения. Это состояние
  // «проверяется», а не «мёртв», иначе выглядит как поломка.
  if (pending > 0) {
    head.push(line(_("проверяется"), String(pending),
      _("узлы добавлены недавно, данных наблюдения ещё нет")));
  }

  head.push(line(_("выбран сейчас"), nodes.selected || _("не выбран"),
    nodes.selection === "manual" ? _("закреплён вручную") : _("автоматически, по задержке")));

  if (!list.length) {
    head.push(E("div", { class: "xkop-note" },
      _("Пул пуст: задайте ссылку подписки во вкладке «Подписки».")));
    return card(_("Пул серверов"), head);
  }

  const states = {
    alive: _("жив"),
    dead: _("мёртв"),
    pending: _("ещё не проверялся"),
    unobserved: _("без наблюдения"),
  };


  const details = E("details", { class: "xkop-details" }, [
    E("summary", {}, _("Показать узлы") + " (" + list.length + ")"),
    E("table", { class: "table" }, [
      E("tr", { class: "tr table-titles" }, [
        E("th", { class: "th" }, _("узел")),
        E("th", { class: "th" }, _("состояние")),
        E("th", { class: "th" }, _("задержка")),
        E("th", { class: "th" }, _("проверок")),
        E("th", { class: "th" }, ""),
      ]),
    ].concat(
      list.map(function (n) {
        const current = nodes.selected === n.tag;
        // «Мёртв» без причины — это приговор без разбирательства. Причину
        // называет сам движок, если она у него есть, и число проверок отвечает
        // на главный вопрос: пробовали ли вообще.
        const probes = (n.probes === null || n.probes === undefined) ? "—"
          : (n.failures ? n.probes + " (" + _("отказов ") + n.failures + ")" : String(n.probes));

        return E("tr", { class: "tr" + (current ? " xkop-row-current" : "") }, [
          E("td", { class: "td" }, [
            E("div", {}, n.tag),
            n.state === "dead" && n.last_error
              ? E("div", { class: "xkop-hint-wrap" }, n.last_error) : "",
          ]),
          E("td", { class: "td xkop-state-" + n.state }, states[n.state] || n.state),
          E("td", { class: "td" }, n.delay_ms === null || n.delay_ms === undefined
            ? "—" : n.delay_ms + " мс"),
          E("td", { class: "td" }, probes),
          E("td", { class: "td" }, [
            current
              ? E("span", { class: "xkop-hint" }, _("выбран"))
              : E("button", {
                  class: "cbi-button cbi-button-apply",
                  click: ui.createHandlerFn(this, function () {
                    return api.select(n.tag).then(refresh);
                  }),
                }, _("закрепить")),
          ]),
        ]);
      })
    )),
  ]);

  const controls = E("div", { class: "xkop-controls" }, [
    E("button", {
      class: "cbi-button cbi-button-neutral",
      click: ui.createHandlerFn(this, function () {
        return api.select("auto").then(refresh);
      }),
    }, _("Вернуть автовыбор")),
  ]);

  return card(_("Пул серверов"), head.concat([details, controls]));
}

// Подписка сама рассказывает, что с ней. Причина берётся у панели, а не
// придумывается: «достигнут лимит устройств» — не то же самое, что
// «серверов нет», и чинится иначе.
function renderSubscriptions(subs, refresh) {
  const update = E("div", { class: "xkop-controls" }, [
    E("button", {
      class: "cbi-button cbi-button-action",
      click: ui.createHandlerFn(this, function () {
        return api.subscriptionUpdate().then(function (r) {
          ui.addNotification(null,
            E("p", {}, r && r.ok ? _("Подписки обновлены")
                                 : _("Не вышло: ") + ((r && r.error) || "?")),
            r && r.ok ? "info" : "warning");
          return refresh();
        });
      }),
    }, _("Обновить сейчас")),
  ]);

  if (!subs || !subs.length) {
    return card(_("Подписки"), [
      E("div", { class: "xkop-empty" }, _("Подписок нет")),
      E("div", { class: "xkop-note" },
        _("Добавить можно во вкладке «Подписки».")),
    ]);
  }

  const states = {
    ready: _("готова"),
    stale: _("устаревает"),
    empty: _("пустая"),
    rejected: _("отвергнута"),
    blocked: _("отказ панели"),
    absent: _("не задана"),
  };

  return card(_("Подписки"), subs.map(function (s) {
    const rows = [
      line(s.subscription, states[s.state] || s.state, s.servers + _(" серверов")),
    ];

    if (s.panel && s.panel.announce) {
      rows.push(E("div", { class: "xkop-note" }, s.panel.announce));
    }
    if (s.state !== "ready" && s.reason) {
      rows.push(E("div", { class: "xkop-warn-text" }, _("причина: ") + s.reason));
    }
    if (s.userinfo && s.userinfo.total > 0) {
      rows.push(line(_("трафик"),
        api.bytes(s.userinfo.download + s.userinfo.upload) + _(" из ") +
        api.bytes(s.userinfo.total), ""));
    }
    if (s.userinfo && s.userinfo.expire > 0) {
      rows.push(line(_("действует до"),
        new Date(s.userinfo.expire * 1000).toLocaleDateString(), ""));
    }
    return E("div", { class: "xkop-sub" }, rows);
  }).concat([update]));
}

// Строка, которой нет ни у одного роутера: человек узнаёт про свою сеть то,
// чего не знал, и видит, что устройство с этим уже справляется.
function renderCanary(canary) {
  if (!canary || !canary.ok) return "";

  if (canary.state === "disabled") {
    return card(_("Канарейка"), E("div", { class: "xkop-empty" }, _("Выключена")));
  }
  if (canary.state === "unknown") {
    return card(_("Канарейка"), E("div", { class: "xkop-empty" },
      _("Проверить не удалось — это не то же самое, что «сеть чистая»")));
  }
  if (!canary.hijacked) {
    return card(_("Канарейка"), E("div", {}, _("Подмены DNS не обнаружено")));
  }

  return card(_("Канарейка"), [
    E("div", { class: "xkop-warn-text" }, _("Провайдер подменяет DNS-ответы.")),
    E("div", {}, _("Выучены заглушки: ") + (canary.learned || []).join(", ")),
    E("div", { class: "xkop-note" },
      _("Ответы с этими адресами движок отбраковывает сам, откуда бы они ни пришли.")),
  ]);
}

// Главная функция: почему этот сайт ведёт себя так, а не иначе. Ответ —
// наблюдение за тем, что движок сделал, а не наше прочтение своих правил.
function renderExplain() {
  const input = E("input", {
    type: "text",
    class: "cbi-input-text",
    placeholder: "example.com",
  });
  const output = E("div", { class: "xkop-explain-out" });

  function ask() {
    const domain = (input.value || "").trim();
    if (!domain) return Promise.resolve();
    output.textContent = _("Спрашиваю движок…");
    return api.explain(domain).then(function (r) {
      while (output.firstChild) output.removeChild(output.firstChild);

      if (!r.ok) {
        output.appendChild(E("div", { class: "xkop-warn-text" },
          r.error === "access_log_off"
            ? _("Журнал доступа выключен, наблюдать нечем")
            : _("Не получилось: ") + r.error));
        return;
      }

      output.appendChild(line(_("домен"), r.domain, ""));
      output.appendChild(line(_("итог"), r.role || _("неизвестно"),
        r.outbound ? _("исходящий: ") + r.outbound : ""));
      if (r.why) output.appendChild(line(_("почему"), r.why, ""));
      if (r.node) {
        output.appendChild(line(_("узел"), r.node.tag,
          _("подписка: ") + (r.node.subscription || "—")));
      }
      if (r.requests_seen) {
        output.appendChild(line(_("запросов в журнале"), String(r.requests_seen), ""));
      }
    });
  }

  input.addEventListener("keydown", function (ev) {
    if (ev.key === "Enter") { ev.preventDefault(); ask(); }
  });

  const button = E("button", {
    class: "cbi-button cbi-button-action",
    click: ui.createHandlerFn(this, ask),
  }, _("Разобрать"));

  return card(_("Разбор маршрута"), [
    E("div", { class: "xkop-note" },
      _("Куда уходит имя и почему. Ответ берётся из того, что движок сделал с пробным соединением.")),
    E("div", { class: "xkop-explain" }, [input, button]),
    output,
  ]);
}

return L.Class.extend({
  render: function () {
    const root = E("div", { class: "xkop-dashboard" });

    function paint(data) {
      while (root.firstChild) root.removeChild(root.firstChild);

      if (!data || !data.ok) {
        root.appendChild(E("div", { class: "xkop-summary xkop-warn" },
          _("Роутер не ответил: ") + ((data && data.error) || "?")));
        return;
      }

      root.appendChild(renderSummary(data));
      root.appendChild(E("div", { class: "xkop-widgets" }, [
        renderServiceWidget(data, refresh),
        renderTrafficWidget(data.stats),
        renderSavingsWidget(data.stats),
        renderRouterWidget(data),
      ]));
      root.appendChild(renderPool(data.nodes, refresh));
      root.appendChild(renderSubscriptions(data.subscriptions, refresh));
      root.appendChild(renderCanary(data.canary));
      root.appendChild(renderExplain());
    }

    function refresh() {
      return api.dashboard().then(paint);
    }

    return api.dashboard().then(function (data) {
      paint(data);
      // Обзор должен оставаться правдой, пока на него смотрят. Обновление
      // на месте: перезагрузка страницы после каждой кнопки теряет и позицию
      // прокрутки, и раскрытый список узлов.
      poll.add(refresh, 10);
      return root;
    });
  },
});
