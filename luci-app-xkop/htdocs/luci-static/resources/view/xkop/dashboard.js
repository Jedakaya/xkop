"use strict";
"require ui";
"require view.xkop.api as api";

// Главный экран.
//
// Он отвечает не на вопрос «какой пинг у третьего сервера», а на вопрос
// «правильно ли сейчас распределяется трафик». Это и есть работа роутера,
// и именно её надо показывать — см. docs/dashboard.md.
//
// Дисциплина: немногое, сделанное глубоко. Стена виджетов даёт обратный
// эффект — чем больше показано, тем меньше замечено.

function line(label, value, hint) {
  return E("div", { class: "xkop-line" }, [
    E("span", { class: "xkop-label" }, label),
    E("span", { class: "xkop-value" }, value),
    hint ? E("span", { class: "xkop-hint" }, hint) : "",
  ]);
}

function card(title, children) {
  return E("div", { class: "xkop-card" }, [
    E("h3", {}, title),
    E("div", { class: "xkop-card-body" }, children),
  ]);
}

// Одна строка сверху: работает, работает с оговорками, не работает. С
// причиной, а не с пятью зелёными галочками, которые пользователь должен
// истолковать сам.
function renderSummary(check) {
  const summary = (check && check.summary) || "состояние неизвестно";
  const good = summary === "работает";
  return E(
    "div",
    { class: "xkop-summary " + (good ? "xkop-good" : "xkop-warn") },
    summary,
  );
}

// Распределение трафика числом: не обещание, а факт. Если через туннель
// ушло сто процентов, значит списки не применились, и это видно сразу,
// а не по жалобе клиента.
function renderDistribution(stats) {
  if (!stats || !stats.ok || !stats.distribution) {
    return card(
      _("Распределение трафика"),
      E("div", { class: "xkop-empty" }, [
        stats && stats.error
          ? _("Метрики недоступны: ") + stats.error
          : _("Метрики недоступны"),
      ]),
    );
  }

  const d = stats.distribution;
  const total = stats.traffic && stats.traffic.outbound_total
    ? stats.traffic.outbound_total.total
    : 0;
  const tunnelled = d.proxy ? d.proxy.bytes : 0;

  const rows = [
    line(_("напрямую"), api.bytes(d.direct.bytes), api.percent(d.direct.share)),
    line(_("через туннель"), api.bytes(d.proxy.bytes), api.percent(d.proxy.share)),
    line(_("заблокировано"), api.bytes(d.blocked.bytes), api.percent(d.blocked.share)),
  ];

  if (d.service && d.service.bytes > 0) {
    rows.push(line(_("служебное"), api.bytes(d.service.bytes), api.percent(d.service.share)));
  }

  // Та же цифра с другой стороны: для владельца, платящего за серверы, это
  // единственное число, имеющее денежное выражение.
  const saved = total - tunnelled;
  if (total > 0) {
    rows.push(
      E("div", { class: "xkop-note" }, [
        _("Всего прошло ") + api.bytes(total) + ". ",
        _("Без распределения весь этот объём ушёл бы в туннель — сэкономлено ") +
          api.bytes(saved) + ".",
      ]),
    );
  }

  return card(_("Распределение трафика"), rows);
}

// Первое, что нужно человеку, открывшему страницу: работает или нет, и чем
// это включить. Раньше запустить роутер из интерфейса было нечем — только
// командой в консоли, о которой ещё надо знать.
function renderService(data) {
  const svc = (data && data.service) || {};
  const eng = (data && data.engine) || {};
  const running = svc.engine && svc.engine.running;

  const rows = [
    line(_("состояние"), svc.state || _("неизвестно"), ""),
    line(
      _("движок"),
      eng.engine_installed
        ? _("Xray ") + (eng.engine_version || "?")
        : _("не установлен"),
      eng.engine_installed && eng.engine_version_ok === false
        ? _("версия ниже требуемой")
        : "",
    ),
    line(_("автозапуск"), svc.enabled ? _("включён") : _("выключен"), ""),
  ];

  if (!eng.engine_installed) {
    rows.push(
      E("div", { class: "xkop-warn-text" }, _("Без движка маршрутизировать нечем.")),
    );
    rows.push(
      E("div", { class: "xkop-note" },
        _("Поставить: xkop update, либо переустановить установщиком с GitHub.")),
    );
  }

  function act(action, label, style) {
    return E("button", {
      class: "cbi-button " + style,
      click: ui.createHandlerFn(this, function () {
        return api.service(action).then(function (r) {
          if (!r || !r.ok) {
            ui.addNotification(null, E("p", {}, _("Не вышло: ") + ((r && r.error) || "?")), "error");
            return;
          }
          // Показывается то, что стало, а не то, что мы просили сделать.
          ui.addNotification(null, E("p", {}, _("Состояние: ") + (r.state || "?")),
            r.engine && r.engine.running ? "info" : "warning");
          location.reload();
        });
      }),
    }, label);
  }

  const controls = E("div", { class: "xkop-controls" }, [
    running ? act("restart", _("Перезапустить"), "cbi-button-apply")
            : act("start", _("Запустить"), "cbi-button-apply"),
    " ",
    running ? act("stop", _("Остановить"), "cbi-button-reset") : "",
    " ",
    svc.enabled ? act("disable", _("Выключить автозапуск"), "")
                : act("enable", _("Включить автозапуск"), ""),
  ]);

  return card(_("Служба"), rows.concat([controls]));
}

// Пул серверов, а не список пингов. Число «7 из 9 живы» полезнее девяти
// чисел в миллисекундах; задержки раскрываются по требованию.
function renderPool(nodes, stats) {
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

  head.push(
    line(
      _("выбран сейчас"),
      nodes.selected || _("не выбран"),
      nodes.selection === "manual" ? _("закреплён вручную") : _("автоматически, по задержке"),
    ),
  );

  const details = E("details", { class: "xkop-details" }, [
    E("summary", {}, _("Показать узлы")),
    E("table", { class: "table" }, [
      E("tr", { class: "tr table-titles" }, [
        E("th", { class: "th" }, _("узел")),
        E("th", { class: "th" }, _("состояние")),
        E("th", { class: "th" }, _("задержка")),
        E("th", { class: "th" }, ""),
      ]),
    ].concat(
      list.map(function (n) {
        const states = {
          alive: _("жив"),
          dead: _("мёртв"),
          pending: _("проверяется"),
          unobserved: _("без наблюдения"),
        };
        return E("tr", { class: "tr" }, [
          E("td", { class: "td" }, n.tag),
          E("td", { class: "td" }, states[n.state] || n.state),
          E("td", { class: "td" }, n.delay_ms === null ? "—" : n.delay_ms + " мс"),
          E("td", { class: "td" }, [
            E("button", {
              class: "cbi-button cbi-button-apply",
              click: ui.createHandlerFn(this, function () {
                return api.select(n.tag).then(function () { location.reload(); });
              }),
            }, _("закрепить")),
          ]),
        ]);
      }, this),
    )),
  ]);

  const controls = E("div", { class: "xkop-controls" }, [
    E("button", {
      class: "cbi-button",
      click: ui.createHandlerFn(this, function () {
        return api.select("auto").then(function () { location.reload(); });
      }),
    }, _("Вернуть автовыбор")),
  ]);

  return card(_("Пул серверов"), head.concat([details, controls]));
}

// Подписка сама рассказывает, что с ней. Причина берётся у панели, а не
// придумывается: «достигнут лимит устройств» — не то же самое, что
// «серверов нет», и чинится иначе.
function renderSubscriptions(subs) {
  if (!subs || !subs.length) {
    return card(_("Подписки"), E("div", { class: "xkop-empty" }, _("Подписок нет")));
  }

  const states = {
    ready: _("готова"),
    stale: _("устаревает"),
    empty: _("пустая"),
    rejected: _("отвергнута"),
    blocked: _("отказ панели"),
    absent: _("не задана"),
  };

  return card(
    _("Подписки"),
    subs.map(function (s) {
      const rows = [
        line(s.subscription, states[s.state] || s.state,
          s.servers + _(" серверов")),
      ];

      if (s.panel && s.panel.announce) {
        rows.push(E("div", { class: "xkop-note" }, s.panel.announce));
      }
      if (s.state !== "ready" && s.reason) {
        rows.push(E("div", { class: "xkop-note" }, _("причина: ") + s.reason));
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
    }),
  );
}

// Строка, которой нет ни у одного роутера: человек узнаёт про свою сеть то,
// чего не знал, и видит, что устройство с этим уже справляется.
function renderCanary(canary) {
  if (!canary || !canary.ok) return "";

  if (canary.state === "disabled") {
    return card(_("Канарейка"), E("div", { class: "xkop-empty" }, _("Выключена")));
  }
  if (canary.state === "unknown") {
    return card(_("Канарейка"),
      E("div", { class: "xkop-empty" }, _("Проверить не удалось — это не то же самое, что «сеть чистая»")));
  }
  if (!canary.hijacked) {
    return card(_("Канарейка"),
      E("div", {}, _("Подмены DNS не обнаружено")));
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

  const button = E("button", {
    class: "cbi-button cbi-button-action",
    click: ui.createHandlerFn(this, function () {
      const domain = (input.value || "").trim();
      if (!domain) return;
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
    }),
  }, _("Разобрать"));

  return card(_("Разбор маршрута"), [
    E("div", { class: "xkop-note" },
      _("Куда уходит имя и почему. Ответ берётся из того, что движок сделал с пробным соединением.")),
    E("div", { class: "xkop-explain" }, [input, button]),
    output,
  ]);
}

return L.Class.extend({
  // Один запуск на всю страницу.
  //
  // Раньше их было пять, и два из них ждали сеть: проверки DNS и FakeIP
  // спрашивают резолвер, а Канарейка вдобавок проверяла подмену и при
  // изменении выученного перезапускала службу. Открытие страницы не имеет
  // права ни ждать сеть, ни что-либо перезапускать.
  render: function () {
    return api.dashboard().then(function (data) {
      if (!data || !data.ok) {
        return E("div", { class: "xkop-dashboard" }, [
          E("div", { class: "xkop-summary xkop-warn" },
            _("Роутер не ответил: ") + ((data && data.error) || "?")),
        ]);
      }

      return E("div", { class: "xkop-dashboard" }, [
        renderSummary(data),
        renderService(data),
        renderDistribution(data.stats),
        renderPool(data.nodes, data.stats),
        renderSubscriptions(data.subscriptions),
        renderCanary(data.canary),
        renderExplain(),
      ]);
    });
  },
});
