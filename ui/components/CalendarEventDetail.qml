import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "../calendar/Calendar.js" as Calendar
import "../message/Html.js" as Html

Rectangle {
  id: root

  required property var controller
  required property var event
  required property color textColor
  required property color backgroundColor
  required property color accentColor
  required property color urgentColor
  required property color dimColor
  required property string panelFontFamily

  signal closed()
  signal editRequested(string sourceId, var event)
  signal deleteRequested(string sourceId, var event)

  readonly property var source: {
    var sources = controller && controller.availableSources
      ? controller.availableSources.sources : []
    var sourceId = String(event && event.sourceId || "")
    for (var i = 0; i < sources.length; i++) {
      if (String(sources[i].id || "") === sourceId) return sources[i]
    }
    return null
  }
  // The button rule: an operation that cannot really run is not drawn. A
  // read-only calendar draws neither button. Google writes against the item
  // id; CalDAV against the event's href, a recurring one is one ICS with
  // state this panel does not re-serialize — and a modified occurrence
  // carries only a RECURRENCE-ID, but its href is the series' shared file —
  // and an href that resolves outside the source's own origin is refused by
  // the same rule the controller applies before any credential is read.
  readonly property bool canWrite: !!root.source && !!event
    && root.source.readOnly !== true
    && (root.source.kind === "google" ? String(event.googleId || "") !== ""
      : root.source.kind === "microsoft" ? String(event.graphId || "") !== ""
      : String(event.href || "") !== "" && String(event.recurrenceRule || "") === ""
        && Number(event.recurrenceIdMs || 0) <= 0
        && String(event.source && event.source.recurrenceId || "") === ""
        && Calendar.caldavEventUrl(root.source.url, event) !== "")
  // What the list left out, read when the event is opened - see
  // CalendarController.loadDetail. Null until it arrives, and for a source
  // whose list already carries everything.
  property var extra: null
  property bool extraLoading: false
  property string extraError: ""
  // Where the back bar leads, named for where the detail was opened from.
  property string backLabel: "Calendar"
  // Off where nobody answers Edit or Delete, so neither is drawn.
  property bool editable: true
  function loadExtra() {
    extra = null
    extraError = ""
    if (!controller || !event || typeof controller.loadDetail !== "function") return
    var asked = event
    extraLoading = true
    controller.loadDetail(event, function(value, error) {
      if (root.event !== asked) return
      root.extraLoading = false
      root.extra = value
      root.extraError = String(error || "")
    })
  }
  onEventChanged: loadExtra()
  Component.onCompleted: loadExtra()
  readonly property string descriptionText: String(extra && extra.description
    || event && event.description || "")
  readonly property var organizer: Calendar.person(extra && extra.organizer || event && event.organizer)
  readonly property var people: Calendar.people(extra ? extra.attendees : (event ? event.attendees : []))
  readonly property var answers: {
    var out = { yes: 0, no: 0, maybe: 0, waiting: 0 }
    for (var i = 0; i < people.length; i++) {
      var p = people[i].partstat
      if (p === "ACCEPTED") out.yes++
      else if (p === "DECLINED") out.no++
      else if (p === "TENTATIVE") out.maybe++
      else out.waiting++
    }
    return out
  }
  function answerLabel(partstat) {
    return ({ ACCEPTED: "Accepted", DECLINED: "Declined", TENTATIVE: "Maybe" })[partstat] || "No answer"
  }
  readonly property string accountLabel: controller && controller.accountLabelFor && event
    ? controller.accountLabelFor(event.sourceId) : ""
  readonly property color eventColor: calendarPalette.colorFor(
    source ? source.colorKey : "accent")
  readonly property string meetingLink: httpLink(event ? event.meetLink : "")
  readonly property string locationLink: httpLink(event ? event.location : "")
  // The location as written. One that is not a link is a place, and a place
  // is something to copy into a message or to look up on a map.
  readonly property string locationText: String(event && event.location || "").trim()
  readonly property bool locationIsPlace: locationText !== "" && locationLink === ""
  readonly property string mapLink: locationIsPlace
    ? "https://www.google.com/maps/search/?api=1&query=" + encodeURIComponent(locationText) : ""
  readonly property string providerLink: httpLink(event ? event.href : "")

  color: root.backgroundColor

  function httpLink(value) {
    return Html.externallyOpenableHttpUrl(value)
  }

  function dateSummary() {
    if (!event || !event.start) return ""
    var start = new Date(Number(event.start.ms || 0))
    var end = event.end ? new Date(Number(event.end.ms || event.start.ms || 0)) : start
    if (event.start.allDay) {
      var inclusiveEnd = new Date(Math.max(start.getTime(), end.getTime() - 1))
      if (start.toDateString() === inclusiveEnd.toDateString())
        return Qt.formatDate(start, "dddd, d MMMM yyyy") + " · All day"
      return Qt.formatDate(start, "d MMMM yyyy") + " – "
        + Qt.formatDate(inclusiveEnd, "d MMMM yyyy") + " · All day"
    }
    var startDay = Qt.formatDate(start, "dddd, d MMMM yyyy")
    if (start.toDateString() === end.toDateString())
      return startDay + " · " + Qt.formatTime(start, "HH:mm") + "–"
        + Qt.formatTime(end, "HH:mm")
    return startDay + " · " + Qt.formatTime(start, "HH:mm") + " – "
      + Qt.formatDate(end, "dddd, d MMMM yyyy") + " · " + Qt.formatTime(end, "HH:mm")
  }

  CalendarPalette {
    id: calendarPalette
    palettePath: root.controller && root.controller.service
      ? String(root.controller.service.calendarPalettePath || "") : ""
    textColor: root.textColor
    accentColor: root.accentColor
    urgentColor: root.urgentColor
    dimColor: root.dimColor
  }

  Flickable {
    id: detailFlick

    WheelScroller { view: detailFlick }

    anchors.fill: parent
    anchors.margins: Style.space(18)
    contentWidth: width
    contentHeight: content.implicitHeight + Style.space(18)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: content
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width, Style.space(720))
      spacing: Style.space(14)

      BackBar {
        label: root.backLabel
        textColor: root.textColor
        dimColor: root.dimColor
        panelFontFamily: root.panelFontFamily
        onActivated: root.closed()
      }

      Rectangle {
        width: parent.width
        height: Style.space(4)
        radius: height / 2
        color: root.eventColor
      }

      Text {
        width: parent.width
        text: String(root.event && root.event.summary || "Untitled event")
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: root.dateSummary()
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(10)
          height: width
          radius: width / 2
          color: root.eventColor
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: (root.source ? String(root.source.name || root.source.id || "Calendar") : "Calendar")
            + (root.accountLabel !== "" ? " · " + root.accountLabel : "")
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
        }
      }

      Row {
        visible: String(root.event && root.event.location || "") !== ""
        width: parent.width
        spacing: Style.space(8)

        ActionIcon {
          anchors.verticalCenter: parent.verticalCenter
          name: "pin"
          iconSize: Style.font.icon
          color: root.dimColor
        }

        Text {
          width: parent.width - Style.space(28)
          text: String(root.event && root.event.location || "")
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WrapAnywhere
          textFormat: Text.PlainText
        }
      }

      Flow {
        visible: root.meetingLink !== "" || root.locationLink !== ""
          || root.providerLink !== "" || (root.canWrite && root.editable) || root.locationText !== ""
        width: parent.width
        spacing: Style.space(7)

        IconTextButton {
          visible: root.canWrite && root.editable
          text: "Edit..."
          iconName: "edit"
          foreground: root.textColor
          accent: root.eventColor
          fontFamily: root.panelFontFamily
          onClicked: root.editRequested(String(root.event.sourceId || ""), root.event)
        }

        IconTextButton {
          visible: root.canWrite && root.editable
          text: "Delete..."
          iconName: "trash"
          foreground: root.urgentColor
          accent: root.urgentColor
          fontFamily: root.panelFontFamily
          onClicked: root.deleteRequested(String(root.event.sourceId || ""), root.event)
        }

        IconTextButton {
          visible: root.meetingLink !== ""
          text: "Join call"
          iconName: "video"
          foreground: root.textColor
          accent: root.eventColor
          fontFamily: root.panelFontFamily
          onClicked: if (root.controller) root.controller.openExternal(root.meetingLink)
        }

        IconTextButton {
          visible: root.locationLink !== "" && root.locationLink !== root.meetingLink
          text: "Open location"
          iconName: "pin"
          foreground: root.textColor
          accent: root.eventColor
          fontFamily: root.panelFontFamily
          onClicked: if (root.controller) root.controller.openExternal(root.locationLink)
        }

        IconTextButton {
          objectName: "event-open-map"
          visible: root.locationIsPlace
          text: "Open in Google Maps"
          iconName: "pin"
          foreground: root.textColor
          accent: root.eventColor
          fontFamily: root.panelFontFamily
          onClicked: if (root.controller) root.controller.openExternal(root.mapLink)
        }

        IconTextButton {
          objectName: "event-copy-location"
          visible: root.locationText !== ""
          text: "Copy location"
          iconName: "pin"
          foreground: root.textColor
          accent: root.eventColor
          fontFamily: root.panelFontFamily
          onClicked: if (root.controller) root.controller.copyText(root.locationText)
        }

        IconTextButton {
          visible: root.providerLink !== "" && root.providerLink !== root.meetingLink
            && root.providerLink !== root.locationLink
          text: "Open in provider"
          iconName: "browser"
          foreground: root.textColor
          accent: root.eventColor
          fontFamily: root.panelFontFamily
          onClicked: if (root.controller) root.controller.openExternal(root.providerLink)
        }
      }

      // Who organised it, who is invited and what they answered.
      PanelSeparator {
        visible: !!root.organizer || root.people.length > 0
        width: parent.width
        foreground: root.textColor
      }

      Text {
        visible: !!root.organizer
        width: parent.width
        text: root.organizer ? "Organised by " + root.organizer.name
          + (root.organizer.email !== "" && root.organizer.email !== root.organizer.name
            ? " <" + root.organizer.email + ">" : "") : ""
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WrapAnywhere
        textFormat: Text.PlainText
      }

      Text {
        visible: !!root.extra && String(root.extra.myPartstat || "") !== ""
        // Exchange marks an invitation it filed on its own as tentative too,
        // so that one is said as where it stands rather than as an answer.
        text: !root.extra ? "" : ({ ACCEPTED: "You accepted", DECLINED: "You declined",
          TENTATIVE: "Tentative in your calendar" })[root.extra.myPartstat] || ""
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
      }

      Column {
        visible: root.people.length > 0
        width: parent.width
        spacing: Style.space(4)

        Text {
          width: parent.width
          text: root.people.length + (root.people.length === 1 ? " person" : " people")
            + " · " + root.answers.yes + " accepted"
            + (root.answers.maybe > 0 ? " · " + root.answers.maybe + " maybe" : "")
            + (root.answers.no > 0 ? " · " + root.answers.no + " declined" : "")
            + (root.answers.waiting > 0 ? " · " + root.answers.waiting + " no answer" : "")
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }

        Repeater {
          // A company-wide invitation can name hundreds; the first fifty are
          // who anybody reads.
          model: root.people.slice(0, 50)

          Item {
            id: attendee
            required property var modelData
            width: parent.width
            implicitHeight: attendeeName.implicitHeight + Style.space(2)

            Text {
              id: attendeeName
              anchors.left: parent.left
              anchors.right: attendeeAnswer.left
              anchors.rightMargin: Style.space(8)
              text: attendee.modelData.name
                + (attendee.modelData.email !== "" && attendee.modelData.email !== attendee.modelData.name
                  ? "  " + attendee.modelData.email : "")
                + (attendee.modelData.optional ? "  (optional)" : "")
              color: root.textColor
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }
            Text {
              id: attendeeAnswer
              anchors.right: parent.right
              anchors.baseline: attendeeName.baseline
              text: root.answerLabel(attendee.modelData.partstat)
              color: attendee.modelData.partstat === "DECLINED" ? root.urgentColor
                : attendee.modelData.partstat === "ACCEPTED" ? root.textColor : root.dimColor
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }
          }
        }

        Text {
          visible: root.people.length > 50
          text: "and " + (root.people.length - 50) + " more"
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }
      }

      Text {
        visible: root.extraLoading || root.extraError !== ""
        width: parent.width
        text: root.extraLoading ? "Loading the rest of the event" : root.extraError
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      PanelSeparator {
        visible: root.descriptionText !== ""
        width: parent.width
        foreground: root.textColor
      }

      Text {
        visible: root.descriptionText !== ""
        width: parent.width
        text: root.descriptionText
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.body
        lineHeight: 1.35
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
      }
    }
  }
}
