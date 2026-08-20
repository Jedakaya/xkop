"use strict";
"require view";
"require form";
"require ui";
"require view.xkop.dashboard as dashboard";
"require view.xkop.settings as settings";

// Точка входа: две вкладки и ничего лишнего.
//
// Обзор отвечает на вопрос «что сейчас происходит», настройки — на вопрос
// «как это устроено». Отдельной вкладки диагностики нет намеренно: экран,
// который надо не забыть открыть, это способ узнавать о поломках последним.
// Проблемы всплывают там же, где живут — в своём блоке обзора.

const CSS = `
.xkop-dashboard { display: flex; flex-direction: column; gap: 1em; }
.xkop-summary { padding: .6em 1em; border-radius: 4px; font-weight: bold; }
.xkop-good { background: #e6f4ea; color: #1e4620; }
.xkop-warn { background: #fdf0e2; color: #6b3b00; }
.xkop-warn-text { color: #a33; font-weight: bold; }
.xkop-card { border: 1px solid rgba(128,128,128,.3); border-radius: 4px; padding: .8em 1em; }
.xkop-card h3 { margin: 0 0 .6em 0; font-size: 1.05em; }
.xkop-line { display: flex; gap: .8em; align-items: baseline; padding: .15em 0; }
.xkop-label { min-width: 12em; opacity: .75; }
.xkop-value { font-weight: bold; }
.xkop-hint { opacity: .6; font-size: .9em; }
.xkop-note { opacity: .7; font-size: .9em; margin-top: .4em; }
.xkop-empty { opacity: .6; }
.xkop-sub { padding: .3em 0; border-bottom: 1px solid rgba(128,128,128,.15); }
.xkop-sub:last-child { border-bottom: none; }
.xkop-details { margin-top: .6em; }
.xkop-explain { display: flex; gap: .5em; margin: .5em 0; }
.xkop-explain input { flex: 1; }
.xkop-explain-out { margin-top: .5em; }
.xkop-controls { margin-top: .6em; }
`;

return view.extend({
  load: function () {
    return dashboard.render();
  },

  // Обзор — такая же вкладка карты, а не блок, приклеенный сверху.
  //
  // Приклеенный сверху блок стоил двух вещей сразу: страница теряла штатный
  // низ LuCI с «Сохранить и применить» (карта, отрисованная внутрь своего
  // div, footer'а не получает), и порядок на странице выглядел случайным —
  // над заголовком настроек висело нечто без объяснения, что это.
  render: function (dashboardView) {
    const map = new form.Map(
      "xkop",
      _("xkop"),
      _("Маршрутизатор трафика на Xray-core. Заблокированное идёт через прокси, остальное напрямую."),
    );
    map.tabbed = true;

    const overview = map.section(form.NamedSection, "settings", "settings", _("Обзор"));
    overview.anonymous = true;
    overview.addremove = false;

    const mount = overview.option(form.DummyValue, "_overview");
    mount.rawhtml = false;
    mount.cfgvalue = function () {
      return dashboardView;
    };

    settings.build(map);

    return map.render().then(function (rendered) {
      return E("div", {}, [E("style", { type: "text/css" }, CSS), rendered]);
    });
  },
});
