"use strict";
"require fs";

// Единственная дверь к роутеру: всё, что показывает панель, приходит из
// команд xkop, а не из чтения конфигурации движка. Формат Xray и адрес его
// эндпоинта интерфейсу знать не положено — см. docs/cli-contract.md.
//
// Команда, которой нечего сказать, возвращает структуру с признаком отказа,
// а не пустоту: пустой ответ неотличим от честного «нет», и на этом уже
// обжигались.

const BIN = "/usr/bin/xkop";

function run(args) {
  return fs
    .exec(BIN, args)
    .then(function (result) {
      if (!result || result.code !== 0 || !result.stdout) {
        return {
          ok: false,
          error: "command_failed",
          detail: { command: args.join(" "), code: result ? result.code : null },
        };
      }
      try {
        return JSON.parse(result.stdout);
      } catch (e) {
        return {
          ok: false,
          error: "bad_output",
          detail: { command: args.join(" ") },
        };
      }
    })
    .catch(function (e) {
      return {
        ok: false,
        error: "not_reachable",
        detail: { command: args.join(" "), message: String(e) },
      };
    });
}

return L.Class.extend({
  run: run,

  // Всё, что показывает обзор, одним запуском. Пять команд на отрисовку
  // страницы стоили секунд ожидания, и две из них лезли в сеть.
  dashboard: function () {
    return run(["dashboard"]);
  },
  service: function (action) {
    return run(["service", action]);
  },

  status: function () {
    return run(["get_status"]);
  },
  stats: function () {
    return run(["stats"]);
  },
  nodes: function () {
    return run(["nodes"]);
  },
  subscriptions: function () {
    return run(["subscriptions"]);
  },
  canary: function () {
    return run(["canary"]);
  },
  globalCheck: function () {
    return run(["global_check"]);
  },
  explain: function (domain) {
    return run(["explain", domain]);
  },
  recent: function (limit) {
    return run(["recent", String(limit || 20)]);
  },
  select: function (tag) {
    return run(["select", tag]);
  },
  subscriptionUpdate: function () {
    return run(["subscription_update"]);
  },
  configure: function () {
    return run(["configure"]);
  },

  // Байты человеку. Округление до одного знака: два уже никто не читает,
  // а без округления цифра прыгает на каждом обновлении.
  bytes: function (value) {
    const units = ["Б", "КБ", "МБ", "ГБ", "ТБ"];
    let n = Number(value) || 0;
    let i = 0;
    while (n >= 1024 && i < units.length - 1) {
      n = n / 1024;
      i++;
    }
    return (i === 0 ? n : n.toFixed(1)) + " " + units[i];
  },

  percent: function (share) {
    return Math.round((Number(share) || 0) * 1000) / 10 + "%";
  },
});
