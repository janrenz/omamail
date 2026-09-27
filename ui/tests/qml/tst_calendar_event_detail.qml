import QtQuick 2.15
import QtTest 1.3
import "../../components" as Omamail

// The detail reads what the list left out when it opens, and draws who is
// invited and what they answered from it.
Item {
  width: 700
  height: 800

  QtObject {
    id: fakeController
    property var service: QtObject { property string calendarPalettePath: "" }
    property var availableSources: ({ sources: [{ id: "ews:work", kind: "ews", name: "Calendar", readOnly: true }] })
    property var asked: []
    property var answer: null
    function loadDetail(event, callback) { asked = asked.concat([event.uid]); callback(answer, "") }
    function accountLabelFor(id) { return "" }
    function openExternal(u) {}
    function copyText(t) {}
  }

  Omamail.CalendarEventDetail {
    id: detail
    anchors.fill: parent
    controller: fakeController
    event: null
    textColor: Qt.rgba(0.9, 0.9, 0.9, 1)
    backgroundColor: Qt.rgba(0.1, 0.1, 0.1, 1)
    accentColor: Qt.rgba(0.4, 0.6, 1, 1)
    urgentColor: Qt.rgba(1, 0.4, 0.4, 1)
    dimColor: Qt.rgba(0.5, 0.5, 0.5, 1)
    panelFontFamily: "monospace"
  }

  TestCase {
    name: "CalendarEventDetail"
    when: windowShown

    function event(uid) {
      return { uid: uid, sourceId: "ews:work", ewsId: "AAMk", summary: "Planning",
        description: "short preview", attendees: [],
        start: { ms: Date.UTC(2026, 8, 28, 8), allDay: false }, end: { ms: Date.UTC(2026, 8, 28, 9), allDay: false } }
    }

    function test_opening_an_event_reads_its_people_and_body() {
      fakeController.answer = {
        description: "The full agenda",
        organizer: { email: "dana@example.org", displayName: "Dana" },
        attendees: [{ email: "ari@example.org", displayName: "Ari", response: "accepted" },
                    { email: "bo@example.org", displayName: "Bo", response: "declined", optional: true }],
        myPartstat: "TENTATIVE"
      }
      detail.event = event("one")
      compare(fakeController.asked, ["one"])
      compare(detail.people.length, 2)
      compare(detail.answers.yes, 1)
      compare(detail.answers.no, 1)
      compare(detail.organizer.name, "Dana")
      compare(detail.descriptionText, "The full agenda", "the whole body, not the list's preview")
    }

    function test_without_a_detail_the_list_event_is_what_is_shown() {
      fakeController.answer = null
      detail.event = event("two")
      compare(detail.descriptionText, "short preview")
      compare(detail.people.length, 0)
      verify(!detail.extraLoading)
    }
  }
}
