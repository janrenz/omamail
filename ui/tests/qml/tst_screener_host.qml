import QtQuick 2.15
import QtTest 1.3
import "../../account" as Account

// The Screener against an account: that a decision moves the sender's mail
// through the account's own action machinery, that a place's folder is
// created and read back before the first move into it, that a sweep after an
// inbox listing moves decided senders only, and that Bubble Up is keyed by
// the message's Message-ID. The account is a stand-in with exactly the
// members ScreenerHost reaches for.
Item {
  QtObject {
    id: fakeAccount
    property string providerId: "imap"
    property var capabilityRefusals: []
    property var screenerState: null
    property string mailboxKey: "inbox"
    property string rawQuery: ""
    property string searchQuery: ""
    property bool ready: true
    property var backend: null
    property var messages: []
    property var labels: []
    property var actions: []
    property var notes: []
    property var failures: []
    property var created: []
    property var saved: null
    signal listRefreshed()
    property QtObject labelActions: QtObject {
      function reloadLabels() {
        fakeAccount.labels = fakeAccount.labels.concat(fakeAccount.created.map(function(name) {
          return { id: name, name: name }
        }))
      }
    }
    property QtObject api: QtObject {
      function createLabel(name, callback) {
        fakeAccount.created = fakeAccount.created.concat([name])
        Qt.callLater(function() { callback({}, "") })
      }
    }
    function runNativeAction(ids, action) { actions = actions.concat([ids.join(",") + " " + action]); return true }
    function act(id, action) { actions = actions.concat([id + " " + action]); return true }
    function note(text) { notes = notes.concat([text]) }
    function fail(text) { failures = failures.concat([text]) }
    function refresh() {}
  }

  Account.ScreenerHost {
    id: host
    account: fakeAccount
    onSaveRequested: function(value) {
      fakeAccount.saved = value
      fakeAccount.screenerState = value
    }
  }

  TestCase {
    name: "ScreenerHost"
    when: windowShown

    function row(id, email, date, extra) {
      var value = { id: id, from: { email: email }, date: date, inInbox: true, unread: true,
                    starred: false, messageId: "<" + id + "@x>", subject: "S " + id }
      for (var key in (extra || {})) value[key] = extra[key]
      return value
    }

    function init() {
      fakeAccount.screenerState = null
      fakeAccount.labels = [{ id: "INBOX", name: "INBOX" }]
      fakeAccount.created = []
      fakeAccount.actions = []
      fakeAccount.notes = []
      fakeAccount.failures = []
      fakeAccount.messages = []
      fakeAccount.mailboxKey = "inbox"
      fakeAccount.providerId = "imap"
    }

    function test_turning_it_on_makes_the_folders_once() {
      host.enable()
      compare(fakeAccount.saved.on, true)
      tryCompare(fakeAccount, "created", ["The Feed", "Paper Trail", "Set Aside", "Bubble Up", "Screened Out"])
      tryVerify(function() { return fakeAccount.notes.indexOf("The Screener is on") >= 0 })
      host.ensureFolders(function() {})
      compare(fakeAccount.created.length, 5, "folders already there are not made again")
    }

    function test_a_decision_moves_the_senders_mail_into_its_place() {
      fakeAccount.screenerState = { on: true, since: "2026-09-01T00:00:00Z" }
      fakeAccount.labels = [{ id: "INBOX", name: "INBOX" }, { id: "The Feed", name: "The Feed" },
        { id: "Paper Trail", name: "Paper Trail" }, { id: "Set Aside", name: "Set Aside" },
        { id: "Bubble Up", name: "Bubble Up" }, { id: "Screened Out", name: "Screened Out" }]
      fakeAccount.messages = [row("a", "news@x.y", "2026-09-10T00:00:00Z"), row("b", "other@x.y", "2026-09-10T00:00:00Z"),
        row("c", "NEWS@x.y", "2026-09-11T00:00:00Z")]
      host.decide(fakeAccount.messages[0], "feed")
      compare(fakeAccount.saved.senders["news@x.y"], "feed")
      compare(fakeAccount.actions, ["a,c label:The Feed"], "only that sender's mail, in one action")
    }

    function test_letting_someone_in_moves_nothing() {
      fakeAccount.screenerState = { on: true, since: "2026-09-01T00:00:00Z" }
      fakeAccount.messages = [row("a", "friend@x.y", "2026-09-10T00:00:00Z")]
      host.decide(fakeAccount.messages[0], "imbox")
      compare(fakeAccount.saved.senders["friend@x.y"], "imbox")
      compare(fakeAccount.actions, [])
    }

    function test_a_move_waits_for_a_folder_that_has_to_be_made() {
      fakeAccount.screenerState = { on: true, since: "2026-09-01T00:00:00Z" }
      fakeAccount.messages = [row("a", "spam@x.y", "2026-09-10T00:00:00Z")]
      host.decide(fakeAccount.messages[0], "out")
      compare(fakeAccount.actions, [], "nothing moves before the folder exists")
      tryCompare(fakeAccount, "actions", ["a label:Screened Out"])
    }

    function test_the_sweep_moves_decided_senders_after_an_inbox_listing() {
      fakeAccount.labels = [{ id: "INBOX", name: "INBOX" }, { id: "The Feed", name: "The Feed" },
        { id: "Paper Trail", name: "Paper Trail" }, { id: "Set Aside", name: "Set Aside" },
        { id: "Bubble Up", name: "Bubble Up" }, { id: "Screened Out", name: "Screened Out" }]
      fakeAccount.screenerState = { on: true, since: "2026-09-01T00:00:00Z",
        senders: { "shop@x.y": "papertrail", "friend@x.y": "imbox" } }
      fakeAccount.messages = [row("r", "shop@x.y", "2026-09-12T00:00:00Z"), row("f", "friend@x.y", "2026-09-12T00:00:00Z"),
        row("n", "new@x.y", "2026-09-12T00:00:00Z")]
      fakeAccount.listRefreshed()
      tryCompare(fakeAccount, "actions", ["r label:Paper Trail"])
      compare(host.placeCounts.screener, 1, "the new sender is counted as waiting")

      fakeAccount.actions = []
      fakeAccount.mailboxKey = "sent"
      fakeAccount.listRefreshed()
      wait(50)
      compare(fakeAccount.actions, [], "no sweep outside the inbox")
    }

    function test_bubble_up_is_keyed_by_message_id() {
      fakeAccount.labels = [{ id: "INBOX", name: "INBOX" }, { id: "The Feed", name: "The Feed" },
        { id: "Paper Trail", name: "Paper Trail" }, { id: "Set Aside", name: "Set Aside" },
        { id: "Bubble Up", name: "Bubble Up" }, { id: "Screened Out", name: "Screened Out" }]
      fakeAccount.screenerState = { on: true, since: "2026-09-01T00:00:00Z" }
      var message = row("m", "friend@x.y", "2026-09-12T00:00:00Z")
      host.bubble(message, "tomorrow")
      verify(!!fakeAccount.saved.bubbles["<m@x>"])
      compare(fakeAccount.actions, ["m label:Bubble Up"])
      host.bubble(row("x", "friend@x.y", "2026-09-12T00:00:00Z", { messageId: "" }), "tomorrow")
      compare(fakeAccount.failures.length, 1, "a message with no Message-ID cannot be found again, and says so")
    }

    function test_reply_later_is_the_flag() {
      host.replyLater(row("s", "friend@x.y", "2026-09-12T00:00:00Z"))
      host.replyLater(row("t", "friend@x.y", "2026-09-12T00:00:00Z", { starred: true }))
      compare(fakeAccount.actions, ["s star", "t unstar"])
    }

    function test_a_provider_without_folders_is_not_offered_it() {
      fakeAccount.providerId = "hey"
      verify(!host.available)
      host.enable()
      compare(fakeAccount.created.length, 0)
      compare(fakeAccount.failures.length, 1)
    }
  }
}
