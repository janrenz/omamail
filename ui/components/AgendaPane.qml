import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../calendar/Calendar.js" as Calendar

// The week ahead, beside the inbox: what the reader shows while no message is
// open, so the mail and the calendar are one view rather than two windows of
// the same app. Today and the six days after it, each day's events in order,
// all-day ones first; the full calendar is still Alt+C.
//
// It asks the calendar controller for those seven days whenever it comes on
// screen and again every few minutes while it stays there. The calendar view
// asks for its own range whenever it opens, so the two do not hold each other
// to one.
Item {
  id: root

  required property var service
  required property color textColor
  required property color accentColor
  required property color dimColor
  required property color dimmerColor
  required property string panelFontFamily
  property color urgentColor: accentColor

  // The event opened from the agenda, shown in its place until it is closed:
  // the reader shows an event the way it shows a message.
  property var openEvent: null

  readonly property var controller: service ? service.calendarController : null
  // Whether there is a calendar to show at all. Without one the reader keeps
  // its own empty state, which teaches the keys instead.
  readonly property bool hasCalendars: !!controller
    && controller.availableSources && Array.isArray(controller.availableSources.sources)
    && controller.availableSources.sources.some(function(s) { return s && s.enabled })

  property double nowMs: Date.now()
  readonly property double todayStart: {
    var now = new Date(nowMs)
    return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  }
  readonly property var days: {
    var out = []
    var start = new Date(todayStart)
    for (var i = 0; i < 7; i++) {
      var day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i)
      out.push({ isoDate: Calendar.isoDate(day), startMs: day.getTime(),
                 endMs: new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1).getTime(),
                 index: i })
    }
    return out
  }
  readonly property var sections: {
    var events = controller ? controller.events : []
    var out = []
    for (var i = 0; i < days.length; i++) {
      var dayEvents = Calendar.eventsOnDay(events, days[i]).filter(function(event) {
        // Today's finished meetings are history; the agenda is what is ahead.
        return !(event.end && event.end.ms < root.nowMs && !event.start.allDay)
      })
      if (dayEvents.length > 0 || i === 0) out.push({ day: days[i], events: dayEvents })
    }
    return out
  }

  function dayLabel(day) {
    if (day.index === 0) return "Today"
    if (day.index === 1) return "Tomorrow"
    var date = new Date(day.startMs)
    var names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return names[date.getDay()] + " " + date.getDate() + " " + months[date.getMonth()]
  }

  function clock(ms) {
    var date = new Date(ms)
    return Calendar.two(date.getHours()) + ":" + Calendar.two(date.getMinutes())
  }

  function timeText(event) {
    if (event.start.allDay) return "All day"
    return clock(event.start.ms) + (event.end ? "–" + clock(event.end.ms) : "")
  }

  function refresh() {
    nowMs = Date.now()
    if (!controller || !visible || !hasCalendars) return
    controller.refresh(todayStart, todayStart + 7 * 86400000)
  }

  onVisibleChanged: if (visible) refresh()
  onHasCalendarsChanged: if (hasCalendars) refresh()
  Component.onCompleted: refresh()

  Timer {
    interval: 5 * 60 * 1000
    running: root.visible
    repeat: true
    onTriggered: root.refresh()
  }

  CalendarEventDetail {
    anchors.fill: parent
    visible: !!root.openEvent
    controller: root.controller
    event: root.openEvent
    backLabel: "Coming up"
    editable: false
    textColor: root.textColor
    backgroundColor: "transparent"
    accentColor: root.accentColor
    urgentColor: root.urgentColor
    dimColor: root.dimColor
    panelFontFamily: root.panelFontFamily
    onClosed: root.openEvent = null
  }

  Flickable {
    id: flick
    visible: !root.openEvent
    anchors.fill: parent
    anchors.margins: Style.space(24)
    contentWidth: width
    contentHeight: agenda.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: agenda
      width: Math.min(flick.width, Style.space(560))
      spacing: Style.space(14)

      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: "Coming up"
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          textFormat: Text.PlainText
        }

        Text {
          anchors.baseline: parent.children[0].baseline
          text: root.controller && root.controller.loading ? "Updating"
            : (root.controller && root.controller.lastError !== "" ? root.controller.lastError : "")
          color: root.dimmerColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width - parent.children[0].width - parent.spacing
          textFormat: Text.PlainText
        }
      }

      Repeater {
        model: root.sections

        Column {
          id: section
          required property var modelData
          width: agenda.width
          spacing: Style.space(4)

          Text {
            text: root.dayLabel(section.modelData.day)
            color: section.modelData.day.index === 0 ? root.accentColor : root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.capitalization: Font.AllUppercase
            textFormat: Text.PlainText
          }

          Text {
            visible: section.modelData.events.length === 0
            text: "Nothing else today"
            color: root.dimmerColor
            font.family: root.panelFontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          Repeater {
            model: section.modelData.events

            Item {
              id: line
              required property var modelData
              width: section.width
              implicitHeight: Math.max(title.implicitHeight + (where.visible ? where.implicitHeight : 0),
                                       when.implicitHeight) + Style.space(6)
              readonly property bool now: !modelData.start.allDay && modelData.start.ms <= root.nowMs
                && modelData.end && modelData.end.ms > root.nowMs

              // Under the Join link, which is declared after it and so wins.
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openEvent = line.modelData
              }

              Text {
                id: when
                width: Style.space(96)
                text: root.timeText(line.modelData)
                color: line.now ? root.accentColor : root.dimColor
                font.family: root.panelFontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }

              Text {
                id: title
                anchors.left: when.right
                anchors.right: join.visible ? join.left : parent.right
                anchors.rightMargin: join.visible ? Style.space(8) : 0
                text: line.modelData.summary || "Untitled event"
                color: root.textColor
                font.family: root.panelFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: line.now
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              Text {
                id: where
                anchors.left: title.left
                anchors.right: title.right
                anchors.top: title.bottom
                visible: text !== ""
                // Whose calendar, where more than one mailbox shares the view.
                text: [String(line.modelData.location || ""),
                       root.controller && root.controller.accountLabelFor ? root.controller.accountLabelFor(line.modelData.sourceId) : ""]
                  .filter(function(part) { return part !== "" }).join(" · ")
                color: root.dimmerColor
                font.family: root.panelFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              // A meeting with a link to join it, joined from here: the link
              // is the event's own, and it opens in the browser the way the
              // calendar's detail does.
              Text {
                id: join
                anchors.right: parent.right
                visible: String(line.modelData.meetLink || "") !== ""
                text: "Join"
                color: root.accentColor
                font.family: root.panelFontFamily
                font.pixelSize: Style.font.caption
                font.underline: joinArea.containsMouse
                textFormat: Text.PlainText

                MouseArea {
                  id: joinArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.service) root.service.openExternal(String(line.modelData.meetLink))
                }
              }
            }
          }
        }
      }
    }
  }
}
