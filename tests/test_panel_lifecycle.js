const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const panelSource = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8");

function extractFunction(name) {
  const start = panelSource.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `Panel.qml must define ${name}()`);
  const open = panelSource.indexOf("{", start);
  assert.notEqual(open, -1, `${name}() must have a body`);

  let depth = 0;
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let i = open; i < panelSource.length; i += 1) {
    const ch = panelSource[i];
    const next = panelSource[i + 1];
    if (lineComment) {
      if (ch === "\n") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (ch === "*" && next === "/") { blockComment = false; i += 1; }
      continue;
    }
    if (quote) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "/" && next === "/") { lineComment = true; i += 1; continue; }
    if (ch === "/" && next === "*") { blockComment = true; i += 1; continue; }
    if (ch === "\"" || ch === "'" || ch === "`") { quote = ch; continue; }
    if (ch === "{") depth += 1;
    else if (ch === "}" && --depth === 0) return panelSource.slice(start, i + 1);
  }
  throw new Error(`Unbalanced body for ${name}()`);
}

function makeHarness(initiallyOpen) {
  let opened = initiallyOpen;
  const barCalls = [];
  const bar = {};
  Object.defineProperty(bar, "centerHoverRevealSuppressed", {
    enumerable: true,
    get() { return false; },
    set() { throw new TypeError('Cannot assign to read-only property "centerHoverRevealSuppressed"'); },
  });
  bar.setCenterHoverRevealSuppressed = (value) => barCalls.push(Boolean(value));

  const root = {
    bar,
    editingLife: false,
    editingEvent: false,
    calendarStatusEntries: [],
    calendarSyncMessage: "",
    calendarPushArmed: false,
    calendarDeleteArmed: false,
    settingsOpen: false,
    expandedAgendaInstanceId: "",
    controller: {
      show() { opened = true; },
      hide() { opened = false; },
    },
    refresh() {},
    refreshCalendar() {},
  };
  Object.defineProperty(root, "opened", { get() { return opened; } });

  const timers = { stop() {} };
  const definitions = [
    extractFunction("setCenterHoverRevealSuppressed"),
    extractFunction("open"),
    extractFunction("close"),
    extractFunction("toggle"),
  ].join("\n");
  const functions = new Function(
    "root", "refresh", "refreshCalendar", "calendarLoadedYear", "viewYear", "calendarPushConfirmation", "calendarDeleteConfirmation",
    `${definitions}\nreturn { open, close, toggle };`,
  )(root, root.refresh, root.refreshCalendar, 2026, 2026, timers, timers);
  root.open = functions.open;
  root.close = functions.close;
  return { root, functions, barCalls, isOpen: () => opened };
}

{
  const harness = makeHarness(true);
  harness.functions.close();
  assert.equal(harness.isOpen(), false, "close() must reach PanelController.hide() with the read-only PluginBarApi facade");
  assert.deepEqual(harness.barCalls, [false], "close() must use the facade mutator rather than assign its read-only property");
}

{
  const harness = makeHarness(false);
  harness.functions.open();
  assert.equal(harness.isOpen(), true, "open() must show the panel");
  harness.functions.close();
  assert.equal(harness.isOpen(), false, "close() must hide the panel");
  harness.functions.toggle();
  assert.equal(harness.isOpen(), true, "toggle() must reopen the panel");
  harness.functions.toggle();
  assert.equal(harness.isOpen(), false, "toggle() must close the reopened panel");
  assert.deepEqual(harness.barCalls, [true, false, true, false]);
}

{
  const panelStart = panelSource.indexOf("\n  KeyboardPanel {");
  const shortcutStart = panelSource.indexOf("\n  Shortcut {");
  const shortcutEnd = panelSource.indexOf("\n  }\n", shortcutStart);
  assert.ok(shortcutStart >= 0 && shortcutEnd >= 0, "Escape must remain available even when PanelKeyCatcher is blocked");
  assert.ok(shortcutStart < panelStart, "Escape Shortcut must sit outside KeyboardPanel's QQuickItem content list");
  const shortcutBlock = panelSource.slice(shortcutStart, shortcutEnd + 5);
  assert.ok(shortcutBlock.includes('sequence: "Escape"'));
  assert.ok(shortcutBlock.includes("context: Qt.ApplicationShortcut"));
  assert.ok(shortcutBlock.includes("enabled: root.opened && !root.editingEvent && !root.editingLife"));
}

{
  const closeButtonStart = panelSource.indexOf('tooltipText: "Close calendar"');
  assert.ok(closeButtonStart >= 0);
  assert.ok(panelSource.slice(closeButtonStart, closeButtonStart + 300).includes("onClicked: root.close()"));
  assert.ok(panelSource.includes("onCloseRequested: root.close()"));

  assert.ok(panelSource.includes("open: root.opened"));
  assert.ok(panelSource.includes("focusTarget: keyCatcher"));
}

console.log("panel lifecycle regression passed");
