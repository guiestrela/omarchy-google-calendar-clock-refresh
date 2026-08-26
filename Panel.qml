import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "CalendarModel.js" as CalendarModel

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is a read-out rather than a picker: today is the only marked
// day, and the only thing that moves is which month is on screen —
// chevrons, the scroll wheel, and the arrow keys all step it.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "omarchy-google-calendar-clock"
  ipcTarget: "omarchy-google-calendar-clock"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  readonly property string nextWeekStartLabel: Qt.locale().dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)

  // Caldir is the only component that reads the local ICS store. Keeping the
  // QML side on a small JSON contract avoids reimplementing recurrence and
  // timezone parsing in the shell.
  property var calendarEvents: []
  property var calendarEventsByDate: ({})
  property string calendarError: ""
  property bool calendarLoading: false
  property bool calendarPulling: false
  property bool calendarAutoPrefetching: false
  property bool calendarScheduledRefreshing: false
  property bool calendarCreating: false
  property bool calendarPushing: false
  property bool calendarPushArmed: false
  property bool calendarStatusLoading: false
  property string calendarSyncMessage: ""
  property bool calendarCloseAfterSync: false

  // Any calendar operation in flight: the agenda area below the grid goes
  // inert (controls disabled) and a spinner row takes its place. The grid
  // itself stays browsable so the popup never feels frozen.
  readonly property bool calendarBusy: calendarPulling || calendarPushing
    || calendarCreating || calendarMutating || calendarStatusLoading
  readonly property string calendarBusyLabel: calendarPulling
    ? "Pulling latest changes from Google…"
    : calendarPushing ? "Pushing local changes to Google…"
    : calendarCreating ? "Saving the event…"
    : calendarMutating ? "Saving changes…"
    : "Checking sync status…"
  readonly property bool calendarProgressVisible: calendarBusy
    || calendarAutoPrefetching || (calendarLoading && calendarEvents.length === 0)
  readonly property string calendarProgressLabel: calendarBusy
    ? calendarBusyLabel
    : calendarAutoPrefetching ? "Extending cached calendar months…"
    : "Loading calendar…"
  property string calendarPullOutput: ""
  property string calendarAutoPrefetchOutput: ""
  property string calendarScheduledRefreshOutput: ""
  property string calendarStatusOutput: ""
  property string calendarCreateOutput: ""
  property string calendarPushOutput: ""
  property var calendarStatusEntries: []
  property bool calendarRuntimeMissing: false
  property bool calendarRuntimeProbing: false
  property int calendarLoadedYear: -1
  property int calendarRequestedYear: -1
  property string calendarRangeStart: ""
  property string calendarRangeEnd: ""
  readonly property string lastCalendarPull: String(setting("lastCalendarPull", ""))
  readonly property int calendarPrefetchMonths: Math.max(1, Math.min(24, parseInt(setting("calendarPrefetchMonths", 6), 10) || 6))
  property string agendaDateKey: todayKey
  property bool editingEvent: false
  property var selectedAgendaEvent: null
  property string eventMutationScope: "instance"
  property bool calendarMutating: false
  property bool calendarDeleteArmed: false
  property string calendarMutationOutput: ""
  property string calendarMutationAction: ""
  property bool settingsOpen: false
  property bool authStatusLoading: false
  property string authStatusOutput: ""
  property string authMode: "none"
  property string authSession: ""
  property string authStatusError: ""

  // While any editable text control holds focus the key catcher stands down:
  // arrow keys keep editing the field (or do nothing at a string boundary)
  // instead of stepping the calendar month, and Tab walks the form through
  // the window's normal focus chain.
  readonly property bool calendarInputFocused: eventTitleField.activeFocus
    || eventDescriptionField.activeFocus || eventTimeField.activeFocus
    || eventRepeatCountField.activeFocus
  property string eventRepeatMode: "none"
  property string originalEventRecurrenceRule: ""
  property bool eventAllDayEditing: true
  readonly property bool eventTitleOnlyEditing: !!selectedAgendaEvent
    && !!selectedAgendaEvent.event_title_only
  property string expandedAgendaInstanceId: ""
  readonly property var eventRepeatOptions: [
    { value: "none", icon: "1", label: "ONCE" },
    { value: "daily", icon: "D", label: "DAILY" },
    { value: "weekly", icon: "W", label: "WEEKLY" },
    { value: "monthly", icon: "M", label: "MONTHLY" },
    { value: "yearly", icon: "Y", label: "YEARLY" }
  ]
  readonly property var agendaEvents: calendarEventsByDate[agendaDateKey]
    ? calendarEventsByDate[agendaDateKey].events : []
  readonly property var nextMoonPhase: {
    var candidate = null
    for (var i = 0; i < calendarEvents.length; i++) {
      var event = calendarEvents[i]
      if (String(event.calendar || "") !== "moon") continue
      if (String(event.start || "") < String(agendaDateKey)) continue
      if (!candidate || String(event.start) < String(candidate.start)) candidate = event
    }
    return candidate
  }
  readonly property bool agendaHasMoonPhase: {
    for (var i = 0; i < agendaEvents.length; i++) {
      if (String(agendaEvents[i].calendar || "") === "moon") return true
    }
    return false
  }
  readonly property var calendarSlugs: {
    var slugs = []
    for (var i = 0; i < calendarEvents.length; i++) {
      var slug = String(calendarEvents[i].calendar || "")
      if (slug !== "" && slugs.indexOf(slug) === -1) slugs.push(slug)
    }
    slugs.sort()
    return slugs
  }

  // ---- Event reminders and the next-event highlight. eventClock is bumped
  //      every minute by SystemClock so both the highlight and the reminder
  //      sweep re-evaluate without polling timers.
  property date eventClock: new Date()
  property bool eventNotificationsEnabled: String(setting("eventNotifications", "true")).toLowerCase() !== "false"
  readonly property string calendarColorMode: String(setting("calendarColorMode", "google")).toLowerCase() === "theme"
    ? "theme" : "google"
  readonly property int settingsCardWidth: Style.space(300)
  readonly property int settingsCardGap: Style.gapsOut
  readonly property bool settingsCardOnRight: panel.cardOrigin.x + panel.contentWidth
    + settingsCardGap + settingsCardWidth <= panel.screenW - panel.margin
  readonly property bool settingsCardOnLeft: panel.cardOrigin.x
    - settingsCardGap - settingsCardWidth >= panel.margin
  readonly property color themeCalendarPrimary: Color.accent
  readonly property color themeCalendarSecondary: root.colorKey(Color.urgent) !== root.colorKey(Color.accent)
    ? Color.urgent
    : (root.colorKey(Color.muted) !== root.colorKey(Color.accent) ? Color.muted : Color.foreground)

  onSettingsOpenChanged: {
    if (root.settingsOpen) {
      root.refreshAuthStatus()
      Qt.callLater(function() { settingsCard.forceActiveFocus() })
    } else if (root.opened) {
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  // The agenda's highlighted event: the next timed event of the displayed
  // day. Today that means still upcoming; on any other day it is the first
  // timed event of that day.
  readonly property string nextTimedEventKey: root.computeNextTimedEventKey()

  function helperPath(name) {
    var url = String(Qt.resolvedUrl("scripts/" + name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function setupPath() {
    var url = String(Qt.resolvedUrl("setup"))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function uninstallPath() {
    var url = String(Qt.resolvedUrl("uninstall"))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function toggleSettings() {
    root.settingsOpen = !root.settingsOpen
  }

  function refreshAuthStatus() {
    if (authStatusProcess.running) return
    root.authStatusLoading = true
    root.authStatusOutput = ""
    root.authStatusError = ""
    authStatusProcess.command = [root.helperPath("calendar-auth-mode"), "status", "--json"]
    authStatusProcess.running = true
  }

  function switchAuthMode(mode) {
    var target = String(mode || "")
    if (target !== "hosted" && target !== "direct") return
    if (target === root.authMode && root.authMode !== "none") return
    if (!root.bar || typeof root.bar.run !== "function") return

    var launcher = "omarchy-launch-floating-terminal-with-presentation"
    var command = root.calendarRuntimeMissing
      ? Util.shellQuote(root.setupPath()) + (target === "hosted" ? " --hosted" : "")
      : Util.shellQuote(root.helperPath("calendar-auth-mode")) + " switch " + Util.shellQuote(target)
    root.close()
    root.bar.run(launcher + " " + command)
  }

  function setCalendarColorMode(mode) {
    var next = String(mode || "") === "theme" ? "theme" : "google"
    if (next === root.calendarColorMode) return
    root.persistSettings({ calendarColorMode: next })
  }

  // Asks the runtime probe whether the Caldir binaries are installed. The
  // result lands in calendarRuntimeMissing, which drives the setup banner
  // and the sync-action gates.
  function probeCalendarRuntime() {
    if (calendarRuntimeProbeProcess.running) return
    calendarRuntimeProbeProcess.command = [root.helperPath("calendar-runtime-check")]
    calendarRuntimeProbeProcess.running = true
  }

  // Opens a floating terminal running the selected interactive setup flow.
  function runCalendarSetup(mode) {
    if (!root.bar || typeof root.bar.run !== "function") return
    var hosted = String(mode || "") === "hosted"
    var launcher = "omarchy-launch-floating-terminal-with-presentation"
    root.bar.run(launcher + " " + Util.shellQuote(root.setupPath()) + (hosted ? " --hosted" : ""))
    root.close()
  }

  // Full removal must remain an interactive terminal flow: it asks separately
  // before deleting OAuth credentials or local calendar files, then restores
  // the built-in clock in the center of the bar.
  function runPluginUninstall() {
    if (!root.bar || typeof root.bar.run !== "function") return
    var launcher = "omarchy-launch-floating-terminal-with-presentation"
    root.close()
    root.bar.run(launcher + " " + Util.shellQuote(root.uninstallPath()))
  }


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    refresh()
    if (calendarLoadedYear !== viewYear) refreshCalendar(viewYear)
    root.controller.show()
    setCenterHoverRevealSuppressed(true)
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    if (root.editingLife) root.cancelEditingLife()
    if (root.editingEvent) {
      root.editingEvent = false
      root.selectedAgendaEvent = null
      root.calendarDeleteArmed = false
      calendarDeleteConfirmation.stop()
    }
    // Status and operation notes belong to this one opening of the popup;
    // reopening the clock should return to its compact agenda.
    root.calendarStatusEntries = []
    root.calendarSyncMessage = ""
    root.calendarPushArmed = false
    root.calendarDeleteArmed = false
    root.settingsOpen = false
    root.expandedAgendaInstanceId = ""
    calendarPushConfirmation.stop()
    calendarDeleteConfirmation.stop()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.agendaDateKey = root.todayKey
  }

  function refreshCalendar(targetYear) {
    if (calendarProcess.running) return
    var year = targetYear === undefined ? viewYear : Number(targetYear)
    if (!isFinite(year)) year = viewYear
    var first = Model.keyForDate(new Date(year, 0, 1))
    var last = Model.keyForDate(new Date(year, 12, 0))
    calendarLoading = true
    calendarError = ""
    calendarRequestedYear = year
    calendarProcess.command = [root.helperPath("calendar-cache-read")]
    calendarProcess.running = true
  }

  function selectAgendaDate(dateKey) {
    agendaDateKey = dateKey
    expandedAgendaInstanceId = ""
    // The agenda follows the grid in a scrollable panel. A day click should
    // reveal its result immediately instead of making people discover that
    // there is more content below the fold.
    Qt.callLater(function() {
      calendarScroll.contentY = Math.max(0, calendarScroll.contentHeight - calendarScroll.height)
    })
  }

  function startCreatingEvent() {
    selectedAgendaEvent = null
    eventMutationScope = "series"
    eventRepeatMode = "none"
    originalEventRecurrenceRule = ""
    eventAllDayEditing = true
    calendarDeleteArmed = false
    calendarSyncMessage = ""
    expandedAgendaInstanceId = ""
    editingEvent = true
    calendarCreateOutput = ""
    Qt.callLater(function() {
      eventTitleField.text = ""
      eventDescriptionField.text = ""
      eventTimeField.text = ""
      eventRepeatCountField.text = ""
      eventTitleField.forceActiveFocus()
    })
  }

  function startEditingEvent(event) {
    if (!event || event.calendar_read_only) {
      calendarSyncMessage = "This calendar is read-only"
      return
    }
    if (event.event_read_only) {
      calendarSyncMessage = "Google does not allow editing this special event type"
      return
    }
    selectedAgendaEvent = event
    eventMutationScope = event.recurring ? "instance" : "series"
    originalEventRecurrenceRule = String(event.recurrence_rule || "")
    eventRepeatMode = event.recurring ? recurrenceModeFromRule(originalEventRecurrenceRule) : "none"
    eventAllDayEditing = !!event.all_day
    calendarDeleteArmed = false
    calendarSyncMessage = ""
    expandedAgendaInstanceId = ""
    calendarMutationOutput = ""
    editingEvent = true
    Qt.callLater(function() {
      eventTitleField.text = String(event.title || "")
      eventDescriptionField.text = String(event.description || "")
      eventTimeField.text = event.all_day ? "" : root.eventTimeLabel(event)
      eventRepeatCountField.text = event.recurring ? recurrenceCountFromRule(root.originalEventRecurrenceRule) : ""
      eventTitleField.forceActiveFocus()
      eventTitleField.selectAll()
    })
  }

  function cancelEditingEvent() {
    if (calendarCreating || calendarMutating) return
    editingEvent = false
    selectedAgendaEvent = null
    calendarDeleteArmed = false
    calendarDeleteConfirmation.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveLocalEvent() {
    var title = String(eventTitleField.text || "").trim()
    var description = String(eventDescriptionField.text || "").trim()
    var time = String(eventTimeField.text || "").trim()
    // An empty masked TextField exposes its literal separator (`:`) through
    // `text`. Keep that implementation detail out of the helper arguments.
    if (!/[0-9]/.test(time)) time = ""
    var repeatCount = String(eventRepeatCountField.text || "").trim()
    if (title === "") {
      calendarSyncMessage = "Enter an event title"
      eventTitleField.forceActiveFocus()
      return
    }
    var scheduleEditable = !selectedAgendaEvent
      || (selectedAgendaEvent.recurring && eventMutationScope === "series")
    if (scheduleEditable && repeatCount !== ""
        && (!/^\d+$/.test(repeatCount) || Number(repeatCount) < 2 || Number(repeatCount) > 999)) {
      calendarSyncMessage = "Repeat count must be between 2 and 999"
      eventRepeatCountField.forceActiveFocus()
      return
    }
    if (!root.eventAllDayEditing && !/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(time)) {
      calendarSyncMessage = "Time must use HH:MM"
      eventTimeField.forceActiveFocus()
      return
    }
    if (root.eventAllDayEditing) time = ""
    if (selectedAgendaEvent) {
      calendarMutating = true
      calendarMutationAction = "edit"
      calendarMutationOutput = ""
      calendarDeleteArmed = false
      calendarMutationProcess.command = [
        root.helperPath("calendar-mutate"), "edit",
        eventMutationScope,
        String(selectedAgendaEvent.calendar || ""),
        String(selectedAgendaEvent.uid || ""),
        String(selectedAgendaEvent.instance_id || ""),
        String(selectedAgendaEvent.start || ""),
        String(selectedAgendaEvent.end || ""),
        root.eventAllDayEditing ? "true" : "false",
        title, time, recurrenceRuleForMutation(repeatCount), description
      ]
      calendarMutationProcess.running = true
      return
    }
    calendarCreating = true
    calendarCreateOutput = ""
    calendarCreateProcess.command = [
      root.helperPath("calendar-create"),
      title, agendaDateKey, time, eventRepeatMode,
      eventRepeatMode === "none" ? "" : repeatCount,
      description
    ]
    calendarCreateProcess.running = true
  }

  function deleteSelectedEvent() {
    if (!selectedAgendaEvent || calendarMutating) return
    calendarDeleteConfirmation.stop()
    calendarDeleteArmed = false
    calendarMutating = true
    calendarMutationAction = "delete"
    calendarMutationOutput = ""
    calendarMutationProcess.command = [
      root.helperPath("calendar-mutate"), "delete",
      eventMutationScope,
      String(selectedAgendaEvent.calendar || ""),
      String(selectedAgendaEvent.uid || ""),
      String(selectedAgendaEvent.instance_id || ""),
      "--confirm"
    ]
    calendarMutationProcess.running = true
  }

  function mutationTargetLabel() {
    if (!selectedAgendaEvent || !selectedAgendaEvent.recurring) return "the event"
    return eventMutationScope === "series" ? "the whole series" : "this event"
  }

  function deleteConfirmationMessage() {
    if (!selectedAgendaEvent || !selectedAgendaEvent.recurring)
      return "Delete this event locally?"
    if (eventMutationScope === "series")
      return "Delete this whole recurring series locally?"
    return "Delete only this event from the recurring series?"
  }

  function deleteTooltipText() {
    if (!selectedAgendaEvent || !selectedAgendaEvent.recurring)
      return "Delete event"
    return eventMutationScope === "series"
      ? "Delete the whole recurring series"
      : "Delete only this event"
  }

  function eventRepeatLabel() {
    for (var i = 0; i < eventRepeatOptions.length; i++)
      if (eventRepeatOptions[i].value === eventRepeatMode) return eventRepeatOptions[i].label
    return "ONCE"
  }

  function recurrenceModeFromRule(rule) {
    var match = /(?:^|;)FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(?:;|$)/i.exec(String(rule || ""))
    return match ? match[1].toLowerCase() : "weekly"
  }

  function recurrenceCountFromRule(rule) {
    var match = /(?:^|;)COUNT=(\d+)(?:;|$)/i.exec(String(rule || ""))
    return match ? match[1] : ""
  }

  function recurrenceRuleFromControls(count) {
    var frequency = String(eventRepeatMode || "none").toUpperCase()
    if (frequency === "NONE") return ""
    return "FREQ=" + frequency + (count === "" ? "" : ";COUNT=" + count)
  }

  function recurrenceRuleForMutation(count) {
    if (!selectedAgendaEvent || !selectedAgendaEvent.recurring || eventMutationScope !== "series")
      return "keep"
    var originalMode = recurrenceModeFromRule(originalEventRecurrenceRule)
    var originalCount = recurrenceCountFromRule(originalEventRecurrenceRule)
    if (eventRepeatMode === originalMode && count === originalCount) return "keep"
    return recurrenceRuleFromControls(count)
  }

  function eventTooltip(dateKey) {
    var entry = calendarEventsByDate[dateKey]
    var events = entry ? entry.events : []
    if (events.length === 0) return "No events"
    var titles = []
    for (var i = 0; i < events.length && i < 3; i++) titles.push(String(events[i].title || "Untitled event"))
    if (events.length > titles.length) titles.push("+" + (events.length - titles.length) + " more")
    return titles.join("\n")
  }

  function eventCount(dateKey) {
    var entry = calendarEventsByDate[dateKey]
    return entry ? entry.events.length : 0
  }

  function eventColors(dateKey) {
    var entry = calendarEventsByDate[dateKey]
    if (!entry) return []
    if (root.calendarColorMode === "google") return entry.colors

    var colors = []
    for (var i = 0; i < entry.events.length; i++) {
      var color = root.themeCalendarColor(String(entry.events[i].calendar || ""))
      if (colors.indexOf(color) === -1) colors.push(color)
    }
    return colors
  }

  function themeCalendarColor(slug) {
    var value = String(slug || "")
    var index = root.calendarSlugs.indexOf(value)
    if (index < 0) index = 0
    return index % 2 === 0 ? root.themeCalendarPrimary : root.themeCalendarSecondary
  }

  function colorKey(color) {
    return [color.r.toFixed(4), color.g.toFixed(4), color.b.toFixed(4), color.a.toFixed(4)].join(":")
  }

  function displayCalendarColor(event) {
    if (root.calendarColorMode === "theme")
      return root.themeCalendarColor(String((event && event.calendar) || ""))
    return CalendarModel.calendarColor(event) || Color.accent
  }

  function calendarColorForSlug(slug) {
    if (root.calendarColorMode === "theme") return root.themeCalendarColor(slug)
    for (var i = 0; i < calendarEvents.length; i++) {
      if (String(calendarEvents[i].calendar || "") === String(slug)) {
        var color = CalendarModel.calendarColor(calendarEvents[i])
        if (color !== "") return color
      }
    }
    return Color.accent
  }

  function parseCalendarStatus(text) {
    var entries = []
    var active = null
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i]).trim()
      if (line === "") continue
      var match = /^📅\s+(.+?)(\s+\(read-only\))?$/.exec(line)
      if (match) {
        active = { slug: match[1], readOnly: !!match[2], details: [] }
        entries.push(active)
      } else if (active) {
        active.details.push(line)
      }
    }
    return entries
  }

  function eventTimeLabel(event) {
    if (event && event.all_day) return "ALL DAY"
    var start = new Date(event && event.start)
    if (isNaN(start.getTime())) return ""
    return Qt.formatTime(start, "HH:mm")
  }

  function eventKeyFor(event) {
    return CalendarModel.eventKeyFor(event)
  }

  // Highlight only the next upcoming timed event on today. Past and future
  // days are historical/planning views, not a current-next-event state.
  function computeNextTimedEventKey() {
    var now = root.eventClock
    var isToday = root.agendaDateKey === Model.keyForDate(now)
    if (!isToday) return ""
    var entry = root.calendarEventsByDate[root.agendaDateKey]
    if (!entry || !entry.events) return ""
    var bestKey = ""
    var bestStart = -1
    for (var i = 0; i < entry.events.length; i++) {
      var event = entry.events[i]
      if (event.all_day) continue
      var start = new Date(String(event.start || ""))
      if (isNaN(start.getTime())) continue
      if (start.getTime() < now.getTime()) continue
      if (bestStart < 0 || start.getTime() < bestStart) {
        bestStart = start.getTime()
        bestKey = root.eventKeyFor(event)
      }
    }
    return bestKey
  }

  // Fires a desktop notification for each timed event five minutes before
  // its start and again at the start itself. Fired keys are remembered in
  // the widget settings, so a shell restart inside the firing minute cannot
  // double-notify, and missed windows (suspend, shell down) stay missed.
  function evaluateEventReminders() {
    if (!root.eventNotificationsEnabled) return
    if (root.calendarLoading || root.calendarError !== "" || root.calendarEvents.length === 0) return
    var now = root.eventClock
    var days = [Model.keyForDate(now)]
    var tomorrow = new Date(now)
    tomorrow.setDate(tomorrow.getDate() + 1)
    days.push(Model.keyForDate(tomorrow))
    var notified = root.parseNotifiedMap()
    var changed = false
    for (var d = 0; d < days.length; d++) {
      var entry = root.calendarEventsByDate[days[d]]
      if (!entry || !entry.events) continue
      for (var i = 0; i < entry.events.length; i++) {
        var event = entry.events[i]
        if (event.all_day) continue
        var start = new Date(String(event.start || ""))
        if (isNaN(start.getTime())) continue
        var minutes = Math.floor((start.getTime() - now.getTime()) / 60000)
        if (minutes === 5) changed = root.fireEventReminder(event, "5", notified) || changed
        else if (minutes === 0) changed = root.fireEventReminder(event, "0", notified) || changed
      }
    }
    if (root.pruneNotifiedMap(notified, now)) changed = true
    if (changed) root.persistSettings({ calendarNotified: JSON.stringify(notified) })
  }

  function parseNotifiedMap() {
    try {
      var parsed = JSON.parse(String(setting("calendarNotified", "{}")))
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed
    } catch (error) {}
    return {}
  }

  function pruneNotifiedMap(notified, now) {
    var cutoff = now.getTime() - 12 * 60 * 60 * 1000
    var changed = false
    for (var key in notified) {
      var time = new Date(String(notified[key])).getTime()
      if (isNaN(time) || time < cutoff) {
        delete notified[key]
        changed = true
      }
    }
    return changed
  }

  function fireEventReminder(event, when, notified) {
    var notifyKey = root.eventKeyFor(event) + "|" + when
    if (notified[notifyKey]) return false
    notified[notifyKey] = new Date().toISOString()

    var title = String(event.title || "Untitled event")
    var timeLabel = root.eventTimeLabel(event)
    var headline, description
    if (when === "5") {
      headline = "Starting in 5 minutes"
      description = title + (timeLabel !== "" ? " at " + timeLabel : "")
    } else {
      headline = title
      description = "Starting now" + (timeLabel !== "" ? " at " + timeLabel : "")
    }
    var links = CalendarModel.eventMeetingLinks(event)
    if (links.length > 0) description += "\n" + links[0]

    reminderProcess.command = [root.helperPath("calendar-notify"), headline, description]
    reminderProcess.running = true
    return true
  }

  function lastPullLabel() {
    if (lastCalendarPull === "") return "Not pulled from Google yet"
    var date = new Date(lastCalendarPull)
    return isNaN(date.getTime()) ? "Pulled from Google" : "Last pull: " + Qt.formatDateTime(date, "d MMM, HH:mm")
  }

  function prefetchStartDate() {
    // A manual pull should include the month being viewed, not merely the
    // window relative to today. Keep the current year too, so returning home
    // after browsing ahead never leaves an empty cache behind.
    return Model.keyForDate(new Date(Math.min(today.getFullYear(), viewYear), 0, 1))
  }

  function prefetchEndDate() {
    var focus = new Date(viewYear, viewMonth, 1)
    var current = new Date(today.getFullYear(), today.getMonth(), 1)
    if (focus < current) focus = current
    var lastMonth = new Date(focus.getFullYear(), focus.getMonth() + calendarPrefetchMonths, 1)
    var currentYearEnd = new Date(today.getFullYear(), 11, 1)
    if (lastMonth < currentYearEnd) lastMonth = currentYearEnd
    return Model.keyForDate(new Date(lastMonth.getFullYear(), lastMonth.getMonth() + 1, 0))
  }

  function prefetchRangeLabel() {
    var start = new Date(prefetchStartDate() + "T12:00:00")
    var end = new Date(prefetchEndDate() + "T12:00:00")
    return Qt.formatDate(start, "MMM yyyy") + "–" + Qt.formatDate(end, "MMM yyyy")
  }

  // When browsing reaches the last two cached months, fetch another window
  // in a separate process. The current snapshot keeps rendering meanwhile;
  // the updater atomically replaces it and notifies the shell when ready.
  function prefetchThresholdEndDate() {
    return Model.keyForDate(new Date(viewYear, viewMonth + 3, 0))
  }

  function automaticPrefetchStartDate() {
    var lastCachedDay = new Date(calendarRangeEnd + "T12:00:00")
    lastCachedDay.setDate(lastCachedDay.getDate() + 1)
    return Model.keyForDate(lastCachedDay)
  }

  function maybeExtendCalendarCache() {
    if (calendarAutoPrefetchProcess.running || calendarPullProcess.running
        || calendarScheduledRefreshProcess.running || calendarRangeEnd === "") return
    if (calendarRangeEnd >= prefetchThresholdEndDate()) return

    var rangeEnd = prefetchEndDate()
    if (calendarRangeEnd >= rangeEnd) return
    calendarAutoPrefetching = true
    calendarAutoPrefetchOutput = ""
    calendarAutoPrefetchProcess.command = [
      root.helperPath("calendar-pull"),
      automaticPrefetchStartDate(), rangeEnd
    ]
    calendarAutoPrefetchProcess.running = true
  }

  function checkCalendarStatus() {
    // The former status check only inspected the local pending state. Make the
    // toolbar action useful: refresh from Google and report the result.
    pullFromGoogle(true)
  }

  function showSyncResult(message) {
    root.calendarSyncMessage = message
    calendarSyncFeedback.restart()
  }

  function syncErrorMessage(output, fallback) {
    if (String(output || "").indexOf("OAuth session") !== -1
        && String(output || "").indexOf("not found") !== -1)
      return "Google is not connected — run setup --hosted again"
    return output || fallback
  }

  function pullFromGoogle(closeAfterSync) {
    if (calendarPullProcess.running || calendarAutoPrefetchProcess.running
        || calendarScheduledRefreshProcess.running || calendarPushing) return
    if (root.calendarRuntimeMissing) {
      root.probeCalendarRuntime()
      root.calendarSyncMessage = "Caldir runtime is not installed — run setup first"
      return
    }
    root.calendarCloseAfterSync = closeAfterSync === true
    calendarPulling = true
    calendarSyncMessage = "Pulling latest changes from Google…"
    calendarPullOutput = ""
    calendarPullProcess.command = [
      root.helperPath("calendar-pull"), "--pending", prefetchStartDate(), prefetchEndDate()
    ]
    calendarPullProcess.running = true
  }

  function pushToGoogle(autoConfirm) {
    if (calendarPushProcess.running) return
    if (root.calendarRuntimeMissing) {
      root.probeCalendarRuntime()
      root.calendarSyncMessage = "Caldir runtime is not installed — run setup first"
      return
    }
    if (!autoConfirm && !calendarPushArmed) {
      calendarPushArmed = true
      calendarSyncMessage = "Push local changes to Google? Click upload again to confirm"
      calendarPushConfirmation.restart()
      return
    }
    calendarPushConfirmation.stop()
    calendarPushArmed = false
    calendarCloseAfterSync = true
    calendarPushing = true
    calendarPushOutput = ""
    calendarSyncMessage = "Pushing local changes to Google…"
    calendarPushProcess.command = [root.helperPath("calendar-push"), "--confirm"]
    calendarPushProcess.running = true
  }

  function pushCreatedEventToGoogle() {
    if (root.calendarRuntimeMissing) {
      root.calendarSyncMessage = "Saved locally, but Caldir runtime is not installed"
      calendarSyncFeedback.restart()
      return
    }
    calendarPushing = true
    calendarPushOutput = ""
    calendarSyncMessage = "Event saved locally — syncing with Google…"
    calendarPushProcess.command = [root.helperPath("calendar-push"), "--confirm"]
    calendarPushProcess.running = true
  }

  function scheduledCalendarRefresh() {
    if (calendarScheduledRefreshProcess.running || calendarPullProcess.running
        || calendarAutoPrefetchProcess.running || calendarPushProcess.running) return
    calendarScheduledRefreshing = true
    calendarScheduledRefreshOutput = ""
    calendarScheduledRefreshProcess.command = [root.helperPath("calendar-pull"), "--pending"]
    calendarScheduledRefreshProcess.running = true
  }

  function calendarStatus() {
    return JSON.stringify({
      loading: calendarLoading,
      error: calendarError,
      events: calendarEvents.length,
      selectedDate: agendaDateKey,
      selectedEvents: agendaEvents.length,
      loadedYear: calendarLoadedYear
    })
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
    if (calendarLoadedYear !== next.year) refreshCalendar(next.year)
    maybeExtendCalendarCache()
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // Locale short day names, trimmed of the trailing period some locales
  // carry ("man." -> "MAN") so the header row stays a clean band of caps.
  function weekdayLabel(weekday) {
    return String(Qt.locale().dayName(weekday, Locale.ShortFormat)).replace(/\.$/, "").toUpperCase()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      root.eventClock = clock.date
      root.evaluateEventReminders()
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
    }
  }

  Process {
    id: calendarProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = CalendarModel.parseBridgeOutput(text)
        root.calendarEvents = parsed.events
        root.calendarEventsByDate = CalendarModel.indexEventsByDate(parsed.events)
        root.calendarRangeStart = parsed.rangeStart
        root.calendarRangeEnd = parsed.rangeEnd
        root.calendarError = parsed.error
        if (parsed.error === "") root.calendarLoadedYear = root.calendarRequestedYear
      }
    }
    onExited: function(exitCode) {
      root.calendarLoading = false
      if (exitCode !== 0 && root.calendarError === "")
        root.calendarError = "Calendar refresh failed"
      if (exitCode === 0) root.maybeExtendCalendarCache()
    }
  }

  Process {
    id: calendarPullProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarPullOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarPullOutput += text
    }
    onExited: function(exitCode) {
      root.calendarPulling = false
      if (exitCode === 0) {
        root.persistSettings({ lastCalendarPull: new Date().toISOString() })
        root.showSyncResult("Google calendar synchronized successfully")
        root.calendarStatusEntries = []
        root.calendarStatusOutput = ""
        calendarReloadAfterPull.restart()
      } else if (exitCode === 127) {
        root.calendarRuntimeMissing = true
        root.calendarSyncMessage = "Caldir runtime is not installed — run setup first"
      } else {
        root.calendarSyncMessage = root.syncErrorMessage(root.calendarPullOutput, "Google pull failed")
      }
    }
  }

  Process {
    id: calendarAutoPrefetchProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarAutoPrefetchOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarAutoPrefetchOutput += text
    }
    onExited: function(exitCode) {
      root.calendarAutoPrefetching = false
      if (exitCode === 0)
        calendarReloadAfterPull.restart()
      else
        root.calendarSyncMessage = root.calendarAutoPrefetchOutput || "Could not extend the local calendar cache"
    }
  }

  Process {
    id: calendarScheduledRefreshProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarScheduledRefreshOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarScheduledRefreshOutput += text
    }
    onExited: function(exitCode) {
      root.calendarScheduledRefreshing = false
      if (exitCode === 0) {
        calendarReloadAfterPull.restart()
      } else if (exitCode === 127) {
        root.calendarRuntimeMissing = true
        if (root.calendarEvents.length === 0)
          root.calendarError = "Caldir runtime is not installed — run setup first"
      } else if (root.calendarEvents.length === 0) {
        root.calendarError = root.calendarScheduledRefreshOutput || "Could not initialize the calendar cache"
      }
    }
  }

  Process {
    id: calendarCreateProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarCreateOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarCreateOutput += text
    }
    onExited: function(exitCode) {
      root.calendarCreating = false
      if (exitCode === 0) {
        root.editingEvent = false
        root.pushCreatedEventToGoogle()
      } else {
        root.calendarSyncMessage = root.calendarCreateOutput || "Could not save the local event"
      }
    }
  }

  Process {
    id: calendarMutationProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarMutationOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarMutationOutput += text
    }
    onExited: function(exitCode) {
      root.calendarMutating = false
      if (exitCode === 0) {
        var action = root.calendarMutationAction
        var target = root.mutationTargetLabel()
        root.editingEvent = false
        root.selectedAgendaEvent = null
        root.calendarDeleteArmed = false
        root.calendarSyncMessage = action === "delete"
          ? "Deleted " + target + " locally"
          : "Updated " + target + " locally"
        calendarReloadAfterPull.restart()
      } else {
        root.calendarSyncMessage = root.calendarMutationOutput || "Could not change the local event"
      }
    }
  }

  Process {
    id: calendarPushProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarPushOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarPushOutput += text
    }
    onExited: function(exitCode) {
      root.calendarPushing = false
      if (exitCode === 0) {
        root.showSyncResult("Google calendar synchronized successfully")
        root.calendarStatusEntries = []
        root.calendarStatusOutput = ""
        calendarReloadAfterPull.restart()
      } else if (exitCode === 127) {
        root.calendarRuntimeMissing = true
        root.calendarSyncMessage = "Caldir runtime is not installed — run setup first"
      } else {
        root.calendarSyncMessage = root.syncErrorMessage(root.calendarPushOutput, "Could not push local changes to Google")
      }
    }
  }

  Timer {
    id: calendarPushConfirmation
    interval: 8000
    repeat: false
    onTriggered: {
      root.calendarPushArmed = false
      if (!root.calendarPushing)
        root.calendarSyncMessage = "Google push cancelled"
    }
  }

  Timer {
    id: calendarSyncFeedback
    interval: 3000
    repeat: false
    onTriggered: root.close()
  }

  Timer {
    id: calendarDeleteConfirmation
    interval: 8000
    repeat: false
    onTriggered: {
      root.calendarDeleteArmed = false
      if (!root.calendarMutating)
        root.calendarSyncMessage = "Deletion cancelled"
    }
  }

  Timer {
    id: calendarReloadAfterPull
    interval: 400
    repeat: false
    onTriggered: root.refreshCalendar(root.viewYear)
  }

  // Preload the existing snapshot shortly after the shell creates this
  // plugin. Opening the popup normally needs no process or disk work.
  Timer {
    id: calendarPreloadTimer
    interval: 1200
    repeat: false
    running: true
    onTriggered: {
      root.refreshCalendar(root.today.getFullYear())
      root.probeCalendarRuntime()
    }
  }

  // Re-probe each time the panel opens so the setup banner clears as soon
  // as setup has finished (setup itself closes the panel).
  onOpenedChanged: {
    if (root.opened) root.probeCalendarRuntime()
  }

  Timer {
    interval: 2500
    repeat: false
    running: true
    onTriggered: root.scheduledCalendarRefresh()
  }

  Timer {
    interval: 30 * 60 * 1000
    repeat: true
    running: true
    onTriggered: root.scheduledCalendarRefresh()
  }

  Process {
    id: calendarStatusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarStatusOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarStatusOutput += text
    }
    onExited: function(exitCode) {
      root.calendarStatusLoading = false
      if (exitCode === 0) {
        root.calendarStatusEntries = root.parseCalendarStatus(root.calendarStatusOutput)
        root.calendarSyncMessage = root.calendarStatusEntries.length > 0 ? "" : "No pending calendar changes"
      } else if (exitCode === 127) {
        root.calendarRuntimeMissing = true
        root.calendarSyncMessage = "Caldir runtime is not installed — run setup first"
      } else {
        root.calendarSyncMessage = root.calendarStatusOutput || "Could not check sync status"
      }
    }
  }

  Process {
    id: calendarRuntimeProbeProcess
    onExited: function(exitCode) {
      root.calendarRuntimeMissing = exitCode !== 0
      root.calendarRuntimeProbing = false
    }
  }

  Process {
    id: authStatusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.authStatusOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.authStatusOutput += text
    }
    onExited: function(exitCode) {
      root.authStatusLoading = false
      if (exitCode !== 0) {
        root.authStatusError = root.authStatusOutput || "Could not read Google OAuth settings"
        return
      }
      try {
        var status = JSON.parse(root.authStatusOutput)
        root.authMode = status.mode === "hosted" ? "hosted" : (status.mode === "direct" ? "direct" : "none")
        root.authSession = String(status.session || "")
        root.authStatusError = ""
      } catch (error) {
        root.authStatusError = "Could not read Google OAuth settings"
      }
    }
  }

  Process {
    id: reminderProcess
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.calendarSyncMessage = "Could not send the event notification"
    }
  }

  component SettingsChoiceButton: Button {
    property string optionValue: ""
    property string currentValue: ""
    signal chosen(string value)

    selected: optionValue === currentValue
    bordered: true
    focusable: true
    // Keep the fill stable on hover. Button still paints its immediate hover
    // border, but avoids the animated bright-then-dim fill transition.
    color: selected ? Style.selectedFillFor(foreground, accent) : background
    onClicked: chosen(optionValue)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    // Match Omarchy's native calendar: on a top bar the panel opens directly
    // below the bar instead of being centered in the remaining screen space.
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || root.calendarInputFocused || root.settingsOpen
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.contentFontFamily
              }
            }

            PanelActionButton {
              anchors.top: parent.top
              anchors.right: parent.right
              iconText: "󰒓"
              tooltipText: root.settingsOpen ? "Close calendar settings" : "Calendar settings"
              foreground: root.settingsOpen ? Color.accent : root.contentForeground
              fontFamily: root.contentFontFamily
              focusable: true
              onClicked: root.toggleSettings()
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              onWheel: function(event) {
                // Horizontal wheels and touchpad side-scrolls report y === 0;
                // without this they would every one read as "next month".
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      required property var modelData

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet.
                      color: root.agendaDateKey === modelData.key
                        ? Style.hoverFillFor(root.contentForeground, Color.accent)
                        : "transparent"
                      border.width: (modelData.today || root.agendaDateKey === modelData.key)
                        ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                      Text {
                        anchors.centerIn: parent
                        text: modelData.day
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }

                      Row {
                        visible: root.eventCount(modelData.key) > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(4)
                        spacing: Style.space(3)

                        Repeater {
                          model: root.eventColors(modelData.key)

                          Rectangle {
                            required property var modelData
                            width: Style.space(5)
                            height: width
                            radius: width / 2
                            color: modelData || Color.accent
                          }
                        }
                      }

                      MouseArea {
                        id: dayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectAgendaDate(modelData.key)
                      }

                      PanelToolTip {
                        visible: dayMouse.containsMouse
                        text: root.eventTooltip(modelData.key)
                        fontFamily: root.contentFontFamily
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          // ---- Hairline dividing the calendar rail above from the agenda
          //      controls below, matching the divider convention used by
          //      other Omarchy panels.
          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.12
          }

          // ---- Local Caldir agenda. Changes stay local until the explicit
          //      upload action is confirmed; read-only calendars remain protected.
          Column {
            id: agendaSection
            width: gridColumn.width
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)
            enabled: !root.calendarBusy

            Item {
              width: parent.width
              height: agendaLabel.implicitHeight

              Text {
                id: agendaLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(new Date(root.agendaDateKey + "T12:00:00"), "dddd, MMMM d").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                PanelActionButton {
                  iconText: "󰐕"
                  tooltipText: "Add local event on " + root.agendaDateKey
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !root.editingEvent && !root.calendarCreating && !root.calendarMutating
                  onClicked: root.startCreatingEvent()
                }

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: "Synchronize with Google"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !root.calendarStatusLoading && !root.calendarPulling
                    && !root.calendarPushing && !root.calendarAutoPrefetching
                    && !root.calendarScheduledRefreshing
                  onClicked: root.checkCalendarStatus()
                }

                PanelActionButton {
                  iconText: "↓"
                  tooltipText: "Pull latest from Google"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !root.calendarPulling && !root.calendarAutoPrefetching
                    && !root.calendarStatusLoading && !root.calendarPushing
                    && !root.calendarScheduledRefreshing
                  onClicked: root.pullFromGoogle(true)
                }

                PanelActionButton {
                  iconText: "↑"
                  tooltipText: root.calendarPushArmed
                    ? "Click again to push local changes to Google"
                    : "Push local changes to Google (confirmation required)"
                  foreground: root.calendarPushArmed ? Color.accent : root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !root.calendarPushing && !root.calendarPulling
                    && !root.calendarAutoPrefetching && !root.calendarScheduledRefreshing
                  onClicked: root.pushToGoogle()
                }

              }
            }

            // ---- Hairline separating the agenda toolbar (day label and
            //      sync actions) from the rows below it.
            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.12
            }

            // ---- Setup choices: make the OAuth trade-off explicit before
            //      opening the interactive terminal flow.
            BorderSurface {
              visible: root.calendarRuntimeMissing
              width: parent.width
              height: setupChoices.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.barForeground, root.barForeground)
              borderSpec: Border.controlSpec("normal", root.barForeground, Color.accent)

              Column {
                id: setupChoices
                x: Style.space(6)
                y: Style.space(6)
                width: parent.width - Style.space(12)
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Google sync needs setup. Choose how Google OAuth should work:"
                  color: root.barForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Row {
                  spacing: Style.space(6)

                  Button {
                    text: "Direct setup"
                    tooltipText: "Use your own Google Cloud OAuth client"
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(2)
                    foreground: root.barForeground
                    fontFamily: root.contentFontFamily
                    bordered: true
                    onClicked: root.runCalendarSetup("direct")
                  }

                  Button {
                    text: "Hosted setup"
                    tooltipText: "Use caldir.org's hosted OAuth relay"
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(2)
                    foreground: root.barForeground
                    fontFamily: root.contentFontFamily
                    bordered: true
                    onClicked: root.runCalendarSetup("hosted")
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Direct uses your own Google Cloud client and keeps token refreshes between this machine and Google. Hosted needs no client, but caldir.org relays sign-in and future token refreshes."
                  color: Qt.darker(root.barForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Column {
              visible: root.calendarStatusEntries.length > 0
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: root.calendarStatusEntries

                Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(2)

                  Row {
                    spacing: Style.space(7)

                    Rectangle {
                      width: Style.space(6)
                      height: width
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.calendarColorForSlug(modelData.slug)
                    }

                    Text {
                      text: modelData.slug + (modelData.readOnly ? " (read-only)" : "")
                      color: Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Repeater {
                    model: modelData.details

                    Text {
                      required property var modelData
                      leftPadding: Style.space(13)
                      width: parent.width
                      wrapMode: Text.Wrap
                      text: modelData
                      color: Qt.darker(root.contentForeground, 1.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            Row {
              visible: root.editingEvent && root.selectedAgendaEvent && root.selectedAgendaEvent.recurring
              width: parent.width
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "APPLY TO"
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              PanelActionButton {
                iconText: "1"
                tooltipText: "Apply edits or deletion only to this event"
                foreground: root.eventMutationScope === "instance" ? Color.accent : root.contentForeground
                fontFamily: root.contentFontFamily
                bordered: true
                focusable: true
                enabled: !root.calendarMutating
                onClicked: {
                  root.eventMutationScope = "instance"
                  root.calendarDeleteArmed = false
                  calendarDeleteConfirmation.stop()
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "THIS EVENT"
                color: root.eventMutationScope === "instance" ? Color.accent : Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              PanelActionButton {
                iconText: "∞"
                tooltipText: "Apply edits or deletion to the whole recurring series"
                foreground: root.eventMutationScope === "series" ? Color.accent : root.contentForeground
                fontFamily: root.contentFontFamily
                bordered: true
                focusable: true
                enabled: !root.calendarMutating
                onClicked: {
                  root.eventMutationScope = "series"
                  root.calendarDeleteArmed = false
                  calendarDeleteConfirmation.stop()
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "WHOLE SERIES"
                color: root.eventMutationScope === "series" ? Color.accent : Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              visible: root.editingEvent && (!root.selectedAgendaEvent || root.selectedAgendaEvent.recurring)
              width: parent.width
              spacing: Style.space(5)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedAgendaEvent ? "SCHEDULE" : "REPEAT"
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Repeater {
                model: root.eventRepeatOptions

                PanelActionButton {
                  required property var modelData
                  iconText: modelData.icon
                  tooltipText: modelData.value === "none"
                    ? (root.selectedAgendaEvent ? "A recurring series cannot be converted to one event here" : "Create one event")
                    : "Repeat " + modelData.label.toLowerCase()
                  foreground: root.eventRepeatMode === modelData.value ? Color.accent : root.contentForeground
                  fontFamily: root.contentFontFamily
                  bordered: true
                  focusable: true
                  enabled: !root.calendarCreating && !root.calendarMutating
                    && !root.eventTitleOnlyEditing
                    && (!root.selectedAgendaEvent || (root.eventMutationScope === "series" && modelData.value !== "none"))
                  onClicked: {
                    root.eventRepeatMode = modelData.value
                    if (modelData.value === "none") eventRepeatCountField.text = ""
                  }
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.eventRepeatLabel()
                color: (!root.selectedAgendaEvent || root.eventMutationScope === "series")
                  ? Color.accent : Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: root.eventRepeatMode !== "none"
                anchors.verticalCenter: parent.verticalCenter
                text: "TIMES"
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: eventRepeatCountField
                visible: root.eventRepeatMode !== "none"
                width: Style.space(55)
                height: Style.space(22)
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: "∞"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                verticalPadding: 0
                validator: IntValidator { bottom: 2; top: 999 }
                enabled: (!root.selectedAgendaEvent || root.eventMutationScope === "series")
                  && !root.eventTitleOnlyEditing
                Keys.onReturnPressed: root.saveLocalEvent()
                Keys.onEnterPressed: root.saveLocalEvent()
                Keys.onEscapePressed: root.cancelEditingEvent()
              }
            }

            Row {
              visible: root.editingEvent
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: eventTitleField
                width: parent.width - eventAllDayButton.width - eventTimeField.width
                  - eventSaveButton.width - eventCancelButton.width
                  - (root.selectedAgendaEvent ? eventDeleteButton.width + Style.space(6) : 0) - Style.space(24)
                placeholderText: "Event title"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                Keys.onReturnPressed: root.saveLocalEvent()
                Keys.onEnterPressed: root.saveLocalEvent()
                Keys.onEscapePressed: root.cancelEditingEvent()
              }

              PanelActionButton {
                id: eventAllDayButton
                iconText: root.eventAllDayEditing ? "A" : "T"
                tooltipText: root.eventAllDayEditing ? "All-day event (click for a time)" : "Timed event (click for all day)"
                foreground: root.eventAllDayEditing ? Color.accent : root.contentForeground
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                bordered: true
                focusable: true
                enabled: !root.calendarCreating && !root.calendarMutating
                  && !root.eventTitleOnlyEditing
                onClicked: {
                  root.eventAllDayEditing = !root.eventAllDayEditing
                  root.calendarSyncMessage = ""
                  if (root.eventAllDayEditing) {
                    eventTimeField.text = ""
                  } else {
                    Qt.callLater(function() { eventTimeField.forceActiveFocus() })
                  }
                }
              }

              TextField {
                id: eventTimeField
                width: Style.space(70)
                placeholderText: root.eventAllDayEditing ? "ALL DAY" : "HH:MM"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                enabled: !root.eventAllDayEditing && !root.calendarCreating && !root.calendarMutating
                  && !root.eventTitleOnlyEditing
                // Keep the friendly four-digit flow (0900 -> 09:00), but
                // never let a click or Tab leave the caret in a blank mask
                // slot. Input always resumes at the first missing digit.
                inputMask: "00:00"
                selectByMouse: false

                function nextEditablePosition() {
                  var value = String(text || "")
                  var slots = [0, 1, 3, 4]
                  for (var i = 0; i < slots.length; i++) {
                    var character = value.charAt(slots[i])
                    if (!/[0-9]/.test(character)) return slots[i]
                  }
                  return 5
                }

                function placeCursorAtNextDigit() {
                  if (!activeFocus) return
                  var next = nextEditablePosition()
                  if (cursorPosition !== next) cursorPosition = next
                }

                onActiveFocusChanged: {
                  if (activeFocus) Qt.callLater(placeCursorAtNextDigit)
                }
                onCursorPositionChanged: Qt.callLater(placeCursorAtNextDigit)
                Keys.onReturnPressed: root.saveLocalEvent()
                Keys.onEnterPressed: root.saveLocalEvent()
                Keys.onEscapePressed: root.cancelEditingEvent()
              }

              PanelActionButton {
                id: eventSaveButton
                iconText: "󰄬"
                tooltipText: root.selectedAgendaEvent ? "Save local changes" : "Save locally"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                focusable: true
                enabled: !root.calendarCreating && !root.calendarMutating
                onClicked: root.saveLocalEvent()
              }

              PanelActionButton {
                id: eventDeleteButton
                visible: !!root.selectedAgendaEvent
                iconText: "󰆴"
                tooltipText: root.deleteTooltipText()
                foreground: root.calendarDeleteArmed ? Color.urgent : root.contentForeground
                hoverColor: Color.urgent
                fontFamily: root.contentFontFamily
                focusable: true
                enabled: !root.calendarCreating && !root.calendarMutating
                onClicked: root.deleteSelectedEvent()
              }

              PanelActionButton {
                id: eventCancelButton
                iconText: "󰅖"
                tooltipText: "Cancel"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                focusable: true
                enabled: !root.calendarCreating && !root.calendarMutating
                onClicked: root.cancelEditingEvent()
              }
            }

            Controls.TextArea {
              id: eventDescriptionField
              visible: root.editingEvent
              width: parent.width
              height: visible ? Style.space(52) : 0
              placeholderText: root.eventTitleOnlyEditing
                ? "Descriptions cannot be changed for Google birthdays"
                : "Description (optional)"
              color: root.contentForeground
              placeholderTextColor: Qt.darker(root.contentForeground, 1.6)
              selectionColor: Style.selectionFillFor(root.contentForeground, Color.accent)
              selectedTextColor: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: TextEdit.Wrap
              leftPadding: Style.spacing.controlPaddingX
              rightPadding: Style.spacing.controlPaddingX
              topPadding: Style.spacing.inputPaddingY
              bottomPadding: Style.spacing.inputPaddingY
              enabled: !root.calendarCreating && !root.calendarMutating
                && !root.eventTitleOnlyEditing
              background: BorderSurface {
                color: Style.controlFill(eventDescriptionField.activeFocus,
                  eventDescriptionField.hovered, root.contentForeground, Color.accent)
                borderSpec: Border.controlSpec(eventDescriptionField.activeFocus ? "focus"
                  : (eventDescriptionField.hovered ? "hover-cursor" : "normal"),
                  root.contentForeground, Color.accent)
                radius: Style.cornerRadius
              }
              Keys.onEscapePressed: root.cancelEditingEvent()
              Keys.onPressed: function(event) {
                if ((event.modifiers & Qt.ControlModifier)
                    && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                  root.saveLocalEvent()
                  event.accepted = true
                }
              }
            }

            Text {
              visible: !root.calendarLoading && root.calendarError !== ""
              width: parent.width
              wrapMode: Text.Wrap
              text: root.calendarError
              color: Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: !root.editingEvent && !root.calendarLoading && root.calendarError === ""
                && root.agendaEvents.length === 0 && !root.nextMoonPhase
              text: "No events"
              color: Qt.darker(root.contentForeground, 1.7)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: !root.editingEvent && !root.calendarLoading && root.calendarError === ""
                && !!root.nextMoonPhase && !root.agendaHasMoonPhase
              width: parent.width
              wrapMode: Text.Wrap
              text: "Lunar phase: " + root.nextMoonPhase.title + " — "
                + Qt.formatDate(new Date(root.nextMoonPhase.start + "T12:00:00"), "d MMM")
              color: Qt.darker(root.contentForeground, 1.45)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              // Repeater delegates are inserted into this Column rather than
              // remaining visual children of the Repeater. Emptying the model
              // is therefore the reliable way to remove agenda rows while the
              // event form is active.
              model: root.editingEvent ? [] : root.agendaEvents

              Column {
                id: agendaEvent
                required property var modelData
                width: parent.width
                spacing: Style.space(3)
                property string eventKey: root.eventKeyFor(modelData)
                property bool isNextEvent: root.nextTimedEventKey !== ""
                  && agendaEvent.eventKey === root.nextTimedEventKey
                property var meetingLinks: CalendarModel.eventMeetingLinks(modelData)
                property bool hasDescription: String(modelData.description || "").trim() !== ""
                property bool descriptionExpanded: hasDescription
                  && root.expandedAgendaInstanceId === eventKey

                // The next timed event of the day gets the Style "selected"
                // treatment — the persistent current state — so the eye
                // lands on what comes next without a hover-style wash.
                Rectangle {
                  width: parent.width
                  height: Math.max(Style.space(30), agendaEventRow.implicitHeight + Style.space(8))
                  radius: Style.cornerRadius
                  color: agendaEvent.isNextEvent
                    ? Style.selectedFillFor(root.contentForeground, Color.accent)
                    : "transparent"
                  border.width: agendaEvent.isNextEvent ? Style.spacing.hairline : 0
                  border.color: Style.selectedBorderFor(root.contentForeground, Color.accent)

                  Row {
                    id: agendaEventRow
                    // Inset the row from the highlight frame so the border
                    // clears the calendar indicator and action buttons.
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(5)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(5)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(7)

                    Rectangle {
                      width: Style.spacing.hairline * 2
                      height: Math.max(Style.space(22), eventTitle.implicitHeight)
                      radius: width / 2
                      color: root.displayCalendarColor(modelData)
                    }

                    Text {
                      width: Style.space(58)
                      text: root.eventTimeLabel(modelData)
                      color: Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Item {
                      width: parent.width - Style.space(65) - Style.spacing.hairline * 2 - Style.space(21)
                        - (joinAgendaButton.visible ? joinAgendaButton.width + Style.space(7) : 0)
                        - (modelData.calendar_read_only ? 0 : editAgendaButton.width)
                        - (modelData.calendar_read_only || modelData.event_read_only ? 0 : deleteAgendaButton.width + Style.space(7))
                      height: Math.max(eventTitle.implicitHeight, Style.space(22))

                      Text {
                        id: eventTitle
                        anchors.left: parent.left
                        anchors.right: descriptionChevron.visible ? descriptionChevron.left : parent.right
                        anchors.rightMargin: descriptionChevron.visible ? Style.space(5) : 0
                        elide: Text.ElideRight
                        text: String(modelData.title || "Untitled event")
                        color: agendaEvent.isNextEvent
                          ? Style.selectedStateColor(root.contentForeground, Color.accent)
                          : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: agendaEvent.isNextEvent
                      }

                      Text {
                        id: descriptionChevron
                        visible: agendaEvent.hasDescription
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: agendaEvent.descriptionExpanded ? "⌃" : "⌄"
                        color: Qt.darker(root.contentForeground, 1.35)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      MouseArea {
                        anchors.fill: parent
                        enabled: agendaEvent.hasDescription
                        hoverEnabled: enabled
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.expandedAgendaInstanceId = agendaEvent.descriptionExpanded
                          ? "" : agendaEvent.eventKey
                      }
                    }

Button {
                      id: joinAgendaButton
                      visible: agendaEvent.meetingLinks.length > 0
                      text: "JOIN"
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(3)
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      tooltipText: agendaEvent.meetingLinks.length > 0
                        ? agendaEvent.meetingLinks[0] : ""
                      bordered: true
                      onClicked: {
                        Qt.openUrlExternally(agendaEvent.meetingLinks[0])
                        root.close()
                      }
                    }

                    PanelActionButton {
                      id: editAgendaButton
                      visible: !modelData.calendar_read_only && !modelData.event_read_only
                      iconText: "󰏫"
                      tooltipText: modelData.recurring ? "Edit this event or the whole series locally" : "Edit event locally"
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      enabled: !root.calendarCreating && !root.calendarMutating
                      onClicked: root.startEditingEvent(modelData)
                    }

                    Button {
                      id: deleteAgendaButton
                      visible: !modelData.calendar_read_only && !modelData.event_read_only
                      text: "DEL"
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(3)
                      tooltipText: "Delete event immediately, then sync with Google"
                      foreground: root.calendarDeleteArmed && root.selectedAgendaEvent === modelData
                        ? Color.urgent : root.contentForeground
                      fontFamily: root.contentFontFamily
                      bordered: true
                      enabled: !root.calendarCreating && !root.calendarMutating
                      onClicked: {
                        if (root.selectedAgendaEvent !== modelData) {
                          root.selectedAgendaEvent = modelData
                          root.eventMutationScope = modelData.recurring ? "instance" : "series"
                        }
                        root.deleteSelectedEvent()
                      }
                    }
                  }
                }

                Text {
                  visible: agendaEvent.descriptionExpanded
                  // Indent to the title column: the row's 5px frame inset
                  // plus indicator, gap, and time column.
                  width: parent.width - Style.space(79)
                  x: Style.space(79)
                  wrapMode: Text.Wrap
                  text: String(modelData.description || "")
                  color: Qt.darker(root.contentForeground, 1.35)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

          }

          // All operation progress and transient feedback uses one predictable
          // location below the agenda. Keeping it outside agendaSection also
          // leaves the spinner active while the agenda controls are disabled.
          Row {
            visible: root.calendarProgressVisible || root.calendarSyncMessage !== ""
            width: gridColumn.width
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: statusSpinner.visible ? Style.space(6) : 0

            Text {
              id: statusSpinner
              visible: root.calendarProgressVisible
              anchors.verticalCenter: parent.verticalCenter
              text: "󰄉"
              color: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              transformOrigin: Item.Center
              rotation: 0
              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 800
                loops: Animation.Infinite
                running: root.calendarProgressVisible
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - (statusSpinner.visible ? statusSpinner.implicitWidth + parent.spacing : 0)
              wrapMode: Text.Wrap
              text: root.calendarProgressVisible ? root.calendarProgressLabel : root.calendarSyncMessage
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      BorderSurface {
        id: settingsCard
        visible: root.settingsOpen
        z: 20
        x: root.settingsCardOnRight
          ? keyCatcher.width + panel.padding + Border.right(panel.borderSpec) + root.settingsCardGap
          : root.settingsCardOnLeft
            ? -panel.padding - Border.left(panel.borderSpec) - width - root.settingsCardGap
            : keyCatcher.width - width
        y: -panel.padding - Border.top(panel.borderSpec)
        width: root.settingsCardWidth
        height: settingsColumn.implicitHeight + contentTopInset + contentBottomInset
        color: Color.popups.background
        borderSpec: panel.borderSpec
        padding: Style.spacing.popupPadding
        radius: Style.cornerRadius

        Keys.onEscapePressed: function(event) {
          root.toggleSettings()
          event.accepted = true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
        }

        Column {
          id: settingsColumn
          x: settingsCard.contentLeftInset
          y: settingsCard.contentTopInset
          width: parent.width - settingsCard.contentLeftInset - settingsCard.contentRightInset
          spacing: Style.space(10)

          Item {
            width: parent.width
            height: Math.max(settingsTitle.implicitHeight, settingsCloseButton.implicitHeight)

            Text {
              id: settingsTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "CALENDAR SETTINGS"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              font.letterSpacing: 1
            }

            PanelActionButton {
              id: settingsCloseButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅖"
              tooltipText: "Close calendar settings"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              focusable: true
              onClicked: root.toggleSettings()
            }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.12
          }

          Text {
            width: parent.width
            text: "GOOGLE OAUTH"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.authStatusLoading
              ? "Checking authentication…"
              : root.authStatusError !== "" ? root.authStatusError
              : root.authMode === "none" ? "Not connected"
              : (root.authMode === "hosted" ? "Hosted" : "Direct")
                + (root.authSession !== "" ? " · " + root.authSession : "")
            color: Qt.darker(root.contentForeground, 1.35)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.spacing.md

            SettingsChoiceButton {
              optionValue: "hosted"
              currentValue: root.authMode
              text: "HOSTED"
              tooltipText: "Authenticate through caldir.org"
              foreground: root.contentForeground
              background: Color.popups.background
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              enabled: !root.authStatusLoading
              onChosen: function(value) { root.switchAuthMode(value) }
            }

            SettingsChoiceButton {
              optionValue: "direct"
              currentValue: root.authMode
              text: "DIRECT"
              tooltipText: "Authenticate directly with your Google OAuth client"
              foreground: root.contentForeground
              background: Color.popups.background
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              enabled: !root.authStatusLoading
              onChosen: function(value) { root.switchAuthMode(value) }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Switching signs out the current session and opens the interactive setup flow. Stored direct credentials are preserved."
            color: Qt.darker(root.contentForeground, 1.65)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.12
          }

          Text {
            width: parent.width
            text: "CALENDAR COLORS"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Row {
            spacing: Style.spacing.md

            SettingsChoiceButton {
              optionValue: "google"
              currentValue: root.calendarColorMode
              text: "GOOGLE"
              tooltipText: "Use each calendar's color from Google Calendar"
              foreground: root.contentForeground
              background: Color.popups.background
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onChosen: function(value) { root.setCalendarColorMode(value) }
            }

            SettingsChoiceButton {
              optionValue: "theme"
              currentValue: root.calendarColorMode
              text: "THEME"
              tooltipText: "Use two colors from the active Omarchy theme"
              foreground: root.contentForeground
              background: Color.popups.background
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onChosen: function(value) { root.setCalendarColorMode(value) }
            }
          }

          Row {
            visible: root.calendarColorMode === "theme"
            spacing: Style.space(7)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8)
              height: width
              radius: width / 2
              color: root.themeCalendarPrimary
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8)
              height: width
              radius: width / 2
              color: root.themeCalendarSecondary
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Follows the active Omarchy theme"
              color: Qt.darker(root.contentForeground, 1.65)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.12
          }

          Text {
            width: parent.width
            text: "REMOVE PLUGIN"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Remove this widget, restore the built-in clock in the bar center, and choose whether to delete Google credentials and calendar data."
            color: Qt.darker(root.contentForeground, 1.65)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "Remove plugin and data…"
            tooltipText: "Open the interactive full-uninstall flow"
            fontSize: Style.font.caption
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(2)
            onClicked: root.runPluginUninstall()
          }
        }
      }
    }
  }
}
