import QtQuick
import qs.Commons
import qs.Ui
import "../calendar/Calendar.js" as Calendar

// What is coming up, above the list on a window too narrow for the reader:
// the next few events of today and tomorrow, one line each. The wide window
// shows the whole week in the empty reader instead - see AgendaPane.qml -
// and this is the same view folded to fit, so a narrow window keeps the
// calendar beside the mail rather than losing it.
Column {
  id: root

  required property var service
  required property color textColor
  required property color accentColor
  required property color dimColor
  required property string panelFontFamily
  property bool wanted: false

  readonly property var controller: service ? service.calendarController : null
  readonly property bool hasCalendars: !!controller
    && controller.availableSources && Array.isArray(controller.availableSources.sources)
    && controller.availableSources.sources.some(function(s) { return s && s.enabled })

  property double nowMs: Date.now()
  readonly property double todayStart: {
    var now = new Date(nowMs)
    return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  }
  // Three at most, and nothing that has already ended.
  readonly property var upcoming: {
    var events = controller ? controller.events : []
    var window = { startMs: todayStart, endMs: todayStart + 2 * 86400000 }
    return Calendar.eventsOnDay(events, window).filter(function(event) {
      return event.start.allDay ? event.start.ms >= root.todayStart
        : (event.end ? event.end.ms : event.start.ms) > root.nowMs
    }).slice(0, 3)
  }

  visible: wanted && hasCalendars && upcoming.length > 0
  width: parent ? parent.width : 0
  spacing: Style.space(2)
  topPadding: Style.space(4)
  bottomPadding: Style.space(10)

  function refresh() {
    nowMs = Date.now()
    if (!controller || !wanted || !hasCalendars) return
    controller.refresh(todayStart, todayStart + 7 * 86400000)
  }
  onWantedChanged: refresh()
  onHasCalendarsChanged: refresh()
  Component.onCompleted: refresh()

  Timer {
    interval: 5 * 60 * 1000
    running: root.wanted
    repeat: true
    onTriggered: root.refresh()
  }

  Text {
    x: Style.space(16)
    text: "COMING UP"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    textFormat: Text.PlainText
  }

  Repeater {
    model: root.upcoming

    Text {
      required property var modelData
      x: Style.space(16)
      width: root.width - Style.space(32)
      readonly property bool tomorrow: modelData.start.ms >= root.todayStart + 86400000
      readonly property string when: modelData.start.allDay ? "All day"
        : Calendar.two(new Date(modelData.start.ms).getHours()) + ":"
          + Calendar.two(new Date(modelData.start.ms).getMinutes())
      text: (tomorrow ? "Tomorrow " : "") + when + "  " + (modelData.summary || "Untitled event")
        + (modelData.location ? " · " + modelData.location : "")
      color: !modelData.start.allDay && modelData.start.ms <= root.nowMs ? root.accentColor : root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
  }
}
