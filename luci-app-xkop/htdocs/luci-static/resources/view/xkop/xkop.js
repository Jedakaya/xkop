"use strict";
"require view";
"require form";
"require ui";
"require uci";
"require view.xkop.dashboard as dashboard";
"require view.xkop.settings as settings";

// Точка входа: две вкладки и ничего лишнего.
//
// Обзор отвечает на вопрос «что сейчас происходит», настройки — на вопрос
// «как это устроено». Отдельной вкладки диагностики нет намеренно: экран,
// который надо не забыть открыть, это способ узнавать о поломках последним.
// Проблемы всплывают там же, где живут — в своём блоке обзора.

// Цвета берутся полупрозрачными от текущего текста, а не заданными: тем LuCI
// много, и светлая заливка на тёмной теме делает надпись нечитаемой. Проверять
// это на каждой теме дорого, а не задавать — бесплатно.
const CSS = `
.xkop-dashboard { display: flex; flex-direction: column; gap: 1em; margin-bottom: 1em; }

.xkop-summary { display: flex; align-items: center; gap: .6em;
  padding: .7em 1em; border-radius: 6px; font-weight: bold;
  border: 1px solid rgba(128,128,128,.35); }
.xkop-good { border-left: 4px solid #2f9e44; }
.xkop-warn { border-left: 4px solid #e8590c; }
.xkop-dot { width: .7em; height: .7em; border-radius: 50%; display: inline-block; }
.xkop-dot-good { background: #2f9e44; }
.xkop-dot-warn { background: #e8590c; }
.xkop-warn-text { color: #e03131; font-weight: bold; }

.xkop-widgets { display: grid; gap: 1em;
  grid-template-columns: repeat(auto-fit, minmax(21em, 1fr));
  align-items: start; }
.xkop-widget { border: 1px solid rgba(128,128,128,.3); border-radius: 6px;
  padding: .9em 1.1em; display: flex; flex-direction: column; }
.xkop-widget-title { text-transform: uppercase; font-size: .75em;
  letter-spacing: .08em; opacity: .6; margin-bottom: .5em; }
.xkop-widget-body { display: flex; flex-direction: column; gap: .1em; }
.xkop-widget-note { opacity: .7; font-size: .9em; margin-bottom: .5em; }
.xkop-big { font-size: 1.6em; font-weight: bold; line-height: 1.1; }
.xkop-big-unit { font-size: .6em; opacity: .7; font-weight: normal; }

.xkop-bar { display: flex; height: .8em; border-radius: 4px; overflow: hidden;
  margin: .2em 0 .7em 0; background: rgba(128,128,128,.2); }
.xkop-bar-part { height: 100%; }
.xkop-bar-direct, .xkop-chip.xkop-bar-direct { background: #2f9e44; }
.xkop-bar-proxy, .xkop-chip.xkop-bar-proxy { background: #1971c2; }
.xkop-bar-blocked, .xkop-chip.xkop-bar-blocked { background: #868e96; }
.xkop-bar-service, .xkop-chip.xkop-bar-service { background: #f08c00; }
.xkop-bar-empty { background: rgba(128,128,128,.2); }
.xkop-chip { width: .7em; height: .7em; border-radius: 2px; display: inline-block; }
.xkop-legend { display: flex; align-items: center; gap: .5em; padding: .1em 0; }
.xkop-legend-label { flex: 1; opacity: .8; }
.xkop-legend-value { font-weight: bold; }
.xkop-legend-share { opacity: .6; min-width: 3.5em; text-align: right; }
.xkop-legend-dim { opacity: .6; }

.xkop-card { border: 1px solid rgba(128,128,128,.3); border-radius: 6px; padding: .8em 1em; }
.xkop-card h3 { margin: 0 0 .6em 0; font-size: 1.05em; }
/* Значение не переносится посреди себя: «168.4 МБ» в две строки читается
   как две разные цифры. Подпись жмётся, значение — нет. */
.xkop-line { display: flex; gap: .8em; align-items: baseline;
  padding: .25em 0; flex-wrap: wrap; }
.xkop-label { flex: 1 1 auto; min-width: 7em; opacity: .75; }
.xkop-value { font-weight: bold; white-space: nowrap; }
.xkop-hint { opacity: .6; font-size: .9em; white-space: nowrap; }
.xkop-hint-wrap { opacity: .6; font-size: .9em; }
.xkop-note { opacity: .7; font-size: .9em; margin-top: .4em; }
.xkop-empty { opacity: .6; }
.xkop-sub { padding: .4em 0; border-bottom: 1px solid rgba(128,128,128,.15); }
.xkop-sub:last-child { border-bottom: none; }
.xkop-details { margin-top: .6em; }
.xkop-row-current { font-weight: bold; }
.xkop-state-dead { color: #e03131; }
.xkop-state-pending { opacity: .7; }
.xkop-explain { display: flex; gap: .5em; margin: .5em 0; }
.xkop-explain input { flex: 1; }
.xkop-explain-out { margin-top: .5em; }
.xkop-controls { margin-top: .8em; display: flex; gap: .5em; flex-wrap: wrap; }
`;

return view.extend({
  // uci грузится здесь, а не в форме: списки профилей и каналов строятся
  // на этапе сборки секций, до того как карта успевает загрузиться сама.
  // Без этого «Привязки» оставались двумя полями, куда надо угадать имя.
  load: function () {
    return Promise.all([uci.load("xkop"), dashboard.render()])
      .then(function (r) { return r[1]; });
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

    // Тип секции здесь не совпадает с типом в uci намеренно. LuCI группирует
    // вкладки по data-tab, а туда кладётся именно sectiontype (form.js: 2485).
    // Три секции с типом settings — это одна вкладка на три: выбираешь «Обзор»,
    // подсвечиваются заодно DNS и «Система», и содержимое валится вперемешку.
    // Запись при этом идёт по имени секции, а оно у всех прежнее — settings,
    // так что схема uci не меняется и переносить ничего не надо.
    const overview = map.section(form.NamedSection, "settings", "overview", _("Обзор"));
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
