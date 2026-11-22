const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const panelSource = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8");

function extractFunction(name) {
  const start = panelSource.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `Panel.qml must define ${name}()`);
  let open = panelSource.indexOf("{", start);
  return panelSource.slice(start, closingBrace(panelSource, open) + 1);
}

function closingBrace(source, open) {
  let depth = 0, quote = null, escaped = false, lineComment = false, blockComment = false;
  for (let i = open; i < source.length; i += 1) {
    const ch = source[i], next = source[i + 1];
    if (lineComment) { if (ch === "\n") lineComment = false; continue; }
    if (blockComment) { if (ch === "*" && next === "/") { blockComment = false; i += 1; } continue; }
    if (quote) { if (escaped) escaped = false; else if (ch === "\\") escaped = true; else if (ch === quote) quote = null; continue; }
    if (ch === "/" && next === "/") { lineComment = true; i += 1; continue; }
    if (ch === "/" && next === "*") { blockComment = true; i += 1; continue; }
    if (ch === "\"" || ch === "'" || ch === "`") { quote = ch; continue; }
    if (ch === "{") depth += 1;
    else if (ch === "}" && --depth === 0) return i;
  }
  throw new Error("Unbalanced QML/JS body");
}

function extractProcessHandler(processId) {
  const idStart = panelSource.indexOf(`id: ${processId}`);
  assert.notEqual(idStart, -1, `missing Process ${processId}`);
  const blockEnd = panelSource.indexOf("\n  Process {", idStart + 5);
  const block = panelSource.slice(idStart, blockEnd < 0 ? panelSource.length : blockEnd);
  const marker = "onExited: function(exitCode)";
  const handlerStart = block.indexOf(marker);
  assert.notEqual(handlerStart, -1, `${processId} must handle onExited`);
  const open = block.indexOf("{", handlerStart);
  return `function(exitCode) ${block.slice(open, closingBrace(block, open) + 1)}`;
}

function runQmlFunction(name, vars, receiver) {
  const keys = Object.keys(vars);
  const fn = new Function(...keys, `return (${extractFunction(name)});`)(...keys.map(key => vars[key]));
  return fn.call(receiver || vars.root);
}

function runProcessHandler(processId, root, extras = {}) {
  const vars = { root, ...extras };
  const keys = Object.keys(vars);
  const handler = new Function(...keys, `return (${extractProcessHandler(processId)});`)(...keys.map(key => vars[key]));
  return handler;
}

function saveContext({ ampm = false, hour = "09", minute = "30", period = 0 } = {}) {
  const createProcess = { command: [], running: false };
  const focus = { count: 0, forceActiveFocus() { this.count += 1; } };
  const root = {
    clockUsesAmPm: ampm, eventAllDayEditing: false, selectedAgendaEvent: null,
    calendarCreating: false, calendarMutating: false, calendarRuntimeMissing: false,
    calendarCreateOutput: "", eventRepeatMode: "none", agendaDateKey: "2099-01-01",
    calendarSyncMessage: "", helperPath: name => `/fixture/${name}`,
  };
  const vars = {
    root,
    eventTitleField: { text: "Fixture event", forceActiveFocus() { this.focused = true; } },
    eventDescriptionField: { text: "" },
    eventHourField: { currentIndex: 0, currentText: hour, forceActiveFocus: focus.forceActiveFocus.bind(focus) },
    eventMinuteField: { currentIndex: 0, currentText: minute },
    eventPeriodField: { currentIndex: period, forceActiveFocus: focus.forceActiveFocus.bind(focus) },
    eventRepeatCountField: { text: "", forceActiveFocus() {} },
    selectedAgendaEvent: null, calendarCreating: false, calendarMutating: false,
    calendarMutationAction: "", calendarMutationOutput: "", calendarDeleteArmed: false,
    calendarDeleteConfirmation: { stop() {}, restart() {} },
    calendarMutationProcess: { command: [], running: false },
    calendarCreateOutput: "", calendarCreateProcess: createProcess,
    agendaDateKey: "2099-01-01", eventRepeatMode: "none", eventMutationScope: "series",
    recurrenceRuleForMutation: () => "",
  };
  return { root, vars, createProcess, focus };
}

function deletionContext() {
  const process = { command: [], running: false };
  const timer = { restarts: 0, stops: 0, restart() { this.restarts += 1; }, stop() { this.stops += 1; } };
  const event = { calendar: "fixture", uid: "fixture-series", instance_id: "fixture-series__20260102", recurring: true };
  const root = { selectedAgendaEvent: event, calendarMutating: false, calendarDeleteArmed: false,
    calendarDeleteArmedTarget: "", eventMutationScope: "instance", helperPath: name => `/fixture/${name}`, calendarMutationAction: "",
    calendarMutationOutput: "", calendarSyncMessage: "", deleteConfirmationMessage: () => "Delete locally?",
    mutationTargetLabel: () => "this event" };
  const vars = { root, selectedAgendaEvent: event, calendarMutating: false, calendarDeleteArmed: false,
    calendarDeleteArmedTarget: "", calendarDeleteConfirmation: timer, calendarMutationAction: "",
    calendarMutationOutput: "", calendarMutationProcess: process, eventMutationScope: "instance" };
  return { root, vars, process, timer };
}

function assertButtonCallsDelete(buttonId) {
  const start = panelSource.indexOf(`id: ${buttonId}`);
  assert.notEqual(start, -1);
  const clickStart = panelSource.indexOf("onClicked:", start);
  const call = panelSource.indexOf("root.deleteSelectedEvent()", clickStart);
  assert.ok(clickStart > start && call > clickStart, `${buttonId} should use the confirmed delete flow`);
}

{
  const blockStart = panelSource.indexOf("id: calendarCreateProcess");
  const blockEnd = panelSource.indexOf("\n  Process {", blockStart + 5);
  const createBlock = panelSource.slice(blockStart, blockEnd);
  assert.doesNotMatch(createBlock, /pushCreatedEventToGoogle/, "saving locally must not auto-push to Google");
  assert.match(createBlock, /Saved locally/, "successful create should report the local save");
  assert.match(createBlock, /calendarReloadAfterPull\.restart\(\)/, "successful local save should reload the local cache");
}

{
  const context = saveContext({ ampm: true, hour: "09", minute: "30", period: -1 });
  runQmlFunction("saveLocalEvent", context.vars, context.root);
  assert.equal(context.createProcess.running, false, "missing AM/PM must block event creation");
  assert.match(context.root.calendarSyncMessage, /AM|PM/i);
  assert.equal(context.focus.count, 1, "focus the required period selector");
}

for (const [hour, period, expected] of [["12", 0, "00:15"], ["12", 1, "12:15"], ["09", 1, "21:30"]]) {
  const context = saveContext({ ampm: true, hour, minute: hour === "12" ? "15" : "30", period });
  runQmlFunction("saveLocalEvent", context.vars, context.root);
  assert.equal(context.createProcess.command[3], expected, `${hour} with period index ${period}`);
}

{
  const context = deletionContext();
  const runDelete = () => runQmlFunction("deleteSelectedEvent", context.vars, context.root);
  runDelete();
  assert.equal(context.process.running, false, "first click must only arm deletion");
  assert.equal(context.root.calendarDeleteArmed, true);
  assert.equal(context.timer.restarts, 1);
  runDelete();
  assert.equal(context.process.running, true, "second click within confirmation window commits deletion");
  assert.equal(context.process.command[1], "delete");
  assert.equal(context.process.command[2], "instance");
  assert.equal(context.root.calendarDeleteArmed, false);
  assertButtonCallsDelete("deleteAgendaButton");
  assertButtonCallsDelete("eventDeleteButton");
  assert.doesNotMatch(panelSource, /Delete event immediately, then sync with Google/);
}

{
  const root = { calendarCreating: true, editingEvent: true, calendarCreateOutput: "Saved local event: fixture",
    calendarSyncMessage: "", pushCalls: 0, pushCreatedEventToGoogle() { this.pushCalls += 1; } };
  const reload = { count: 0, restart() { this.count += 1; } };
  const handler = runProcessHandler("calendarCreateProcess", root, { calendarReloadAfterPull: reload });
  handler(0);
  assert.equal(root.pushCalls, 0);
  assert.equal(root.editingEvent, false);
  assert.equal(root.calendarSyncMessage, "Saved local event: fixture");
  assert.equal(reload.count, 1);
}

{
  const context = deletionContext();
  context.root.calendarMutationAction = "delete";
  context.root.calendarMutationOutput = "Deleted this event locally; cache refresh failed";
  context.root.editingEvent = true;
  const reload = { count: 0, restart() { this.count += 1; } };
  const handler = runProcessHandler("calendarMutationProcess", context.root, { calendarReloadAfterPull: reload });
  handler(2);
  assert.equal(context.root.editingEvent, false);
  assert.match(context.root.calendarSyncMessage, /locally.*cache refresh failed/i);
  assert.equal(reload.count, 0, "don't reload stale cache after refresh failure");
}

{
  const notified = {};
  const persisted = {};
  const timer = { restarts: 0, restart() { this.restarts += 1; } };
  const process = { command: [], starts: 0, _running: false,
    set running(value) { this._running = value; if (value) this.starts += 1; }, get running() { return this._running; } };
  const root = {
    reminderInFlightKey: "", reminderAttempts: ({}), calendarSyncMessage: "",
    eventKeyFor: event => event.uid, eventTimeLabel: () => "09:30", helperPath: () => "/fixture/calendar-notify",
    notificationPlainText: value => String(value), parseNotifiedMap: () => ({ ...persisted }),
    persistSettings(update) { Object.assign(persisted, JSON.parse(update.calendarNotified)); },
  };
  const vars = { root, CalendarModel: { eventMeetingLinks: () => [] }, reminderProcess: process };
  const fire = new Function(...Object.keys(vars), `return (${extractFunction("fireEventReminder")});`)(...Object.values(vars));
  const event = { uid: "fixture-event", title: "Fixture", start: "2099-01-01T09:30:00" };
  const handler = runProcessHandler("reminderProcess", root, { reminderRetryTimer: timer });
  assert.equal(fire(event, "0", notified), true);
  assert.equal(Object.hasOwn(notified, "fixture-event|0"), false, "do not mark delivered before helper success");
  assert.equal(root.reminderInFlightKey, "fixture-event|0");
  handler(1);
  assert.equal(root.reminderInFlightKey, "");
  assert.equal(Object.hasOwn(persisted, "fixture-event|0"), false);
  assert.equal(timer.restarts, 1, "first helper failure schedules a bounded retry");
  assert.equal(fire(event, "0", notified), true);
  assert.equal(process.starts, 2);
  handler(1);
  assert.equal(timer.restarts, 2, "second helper failure schedules the final bounded retry");
  assert.equal(fire(event, "0", notified), true);
  assert.equal(process.starts, 3);
  handler(1);
  assert.equal(timer.restarts, 2, "third helper failure stops retries");
  assert.match(root.calendarSyncMessage, /3 attempts/);
  assert.equal(Object.hasOwn(persisted, "fixture-event|0"), false);
  assert.equal(root.reminderInFlightKey, "");
}

{
  const notified = {};
  const persisted = {};
  const process = { command: [], running: false };
  const root = { reminderInFlightKey: "", reminderAttempts: ({}), calendarSyncMessage: "",
    eventKeyFor: event => event.uid, eventTimeLabel: () => "09:30", helperPath: () => "/fixture/calendar-notify",
    notificationPlainText: value => String(value), parseNotifiedMap: () => ({ ...persisted }),
    persistSettings(update) { Object.assign(persisted, JSON.parse(update.calendarNotified)); },
    evaluateEventReminders() {} };
  const handler = runProcessHandler("reminderProcess", root, { reminderRetryTimer: { restart() {} } });
  const fire = new Function("root", "CalendarModel", "reminderProcess", `return (${extractFunction("fireEventReminder")});`)(root, { eventMeetingLinks: () => [] }, process);
  assert.equal(fire({ uid: "fixture-success", title: "Fixture" }, "5", notified), true);
  handler(0);
  assert.equal(Object.hasOwn(persisted, "fixture-success|5"), true, "persist delivered marker only after success");
  assert.equal(root.reminderInFlightKey, "");
}

console.log("Issue #15212 QML regression checks passed");
