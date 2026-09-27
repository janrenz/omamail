import QtQuick
import "Screener.js" as Screener
import "../providers/Registry.js" as Provider

// The Screener and its places, run against one account - see Screener.js for
// the rules. Beside the account rather than in it, which is at its size
// ceiling, the way LabelActions is.
//
// Every move goes through the account's own action machinery, so a decision
// moves rows the way `v` does: optimistically, queued behind an action still
// finishing, and rolled back if the server refuses. The folders a place needs
// are created, and read back, before the first move that needs them.
QtObject {
  id: host

  required property var account

  // What the account entry says; written back through `saveRequested`, which
  // the service turns into a save of accounts.json.
  readonly property var ledger: Screener.normalize(account.screenerState)
  readonly property bool on: ledger.on
  // Only where a place can be a folder or a label and a message can be moved
  // into one. HEY has these places itself; a JMAP server here can neither
  // make a mailbox nor move to one.
  readonly property bool available: account.providerId !== "hey"
    && Provider.can(account.providerId, "move", account.capabilityRefusals)
    && Provider.can(account.providerId, "manageLabels", account.capabilityRefusals)

  // Which place is open: "" is the plain mailbox tree.
  property string place: ""
  signal saveRequested(var value)

  // Counted while the inbox is what is listed, and held while another
  // folder is: the counts are about the inbox, and `messages` is whatever is
  // open.
  property var placeCounts: ({ imbox: 0, screener: 0, replylater: 0 })
  readonly property bool listingInbox: account.mailboxKey === "inbox"
    && account.rawQuery === "" && account.searchQuery === ""
  function recount() {
    if (listingInbox) placeCounts = Screener.counts(account.messages, ledger)
  }
  onLedgerChanged: recount()

  function save(value) { saveRequested(JSON.parse(JSON.stringify(value))) }

  function enable() {
    if (!available) { account.fail("This mailbox cannot hold the Screener's places"); return }
    save(Screener.enabled(ledger))
    // Rules are read once the entry says the Screener is on; if it does not
    // yet, the first sweep reads them.
    ensureFolders(function() { account.note("The Screener is on"); host.pullRules() })
  }

  function disable() {
    var value = Screener.normalize(ledger)
    value.on = false
    place = ""
    save(value)
    clearRules()
  }

  // ---------------------------------------------------------------- folders

  property var afterFolders: []
  property bool creating: false

  function labelIdFor(key) {
    var label = Screener.labelFor(account.labels, key)
    return label ? String(label.id) : ""
  }

  function ensureFolders(done) {
    var missing = Screener.missingFolders(account.labels)
    if (missing.length === 0) { if (typeof done === "function") done(); return }
    if (typeof done === "function") afterFolders = afterFolders.concat([done])
    if (creating) return
    creating = true
    var remaining = missing.length
    for (var i = 0; i < missing.length; i++) {
      var name = missing[i]
      account.api.createLabel(name, function(payload, error) {
        if (!host) return
        if (error) account.fail("Could not create a Screener folder: " + String(error))
        if (--remaining === 0) account.labelActions.reloadLabels()
      })
    }
  }

  // The folders arrive with the label list, and the moves that waited for
  // them go out then.
  property Connections labelWatch: Connections {
    target: host.account
    function onLabelsChanged() {
      if (!host.creating || Screener.missingFolders(host.account.labels).length > 0) return
      host.creating = false
      var waiting = host.afterFolders
      host.afterFolders = []
      for (var i = 0; i < waiting.length; i++) waiting[i]()
    }
  }

  function moveTo(ids, key) {
    if (ids.length === 0) return
    ensureFolders(function() {
      var target = host.labelIdFor(key)
      if (target === "") { host.account.fail("The " + Screener.place(key).folder + " folder is missing"); return }
      host.account.runNativeAction(ids, "label:" + target, true, false, false)
    })
  }

  // ------------------------------------------------------------- decisions

  // Where this sender's mail goes from now on, and the mail of theirs that is
  // in the list goes with it.
  function decide(row, decision) {
    if (!on || !row) return
    var who = Screener.address(row.from)
    if (who === "") return
    save(Screener.decide(ledger, who, decision))
    scheduleRules()
    var folder = Screener.DECISIONS[decision]
    if (folder) {
      var ids = account.messages.filter(function(m) {
        return Screener.address(m.from) === who && m.inInbox !== false
      }).map(function(m) { return String(m.id) })
      moveTo(ids, folder)
    }
    var label = ({ imbox: "the Imbox", feed: "The Feed", papertrail: "the Paper Trail", out: "Screened Out" })[decision]
    account.note(who + " goes to " + label + " from now on")
  }

  function replyLater(row) {
    if (!row) return
    account.act(String(row.id), row.starred === true ? "unstar" : "star")
  }

  function setAside(row) {
    if (!on || !row) return
    moveTo([String(row.id)], "setaside")
    account.note("Set aside")
  }

  function bubble(row, choice) {
    if (!on || !row) return
    var messageId = String(row.messageId || "")
    if (messageId === "") { account.fail("This message has no Message-ID to find it again by"); return }
    var until = Screener.bubbleTime(choice)
    save(Screener.bubble(ledger, messageId, until, row.subject))
    moveTo([String(row.id)], "bubbleup")
    account.note("Bubbles up " + Screener.whenLabel(until))
  }

  // ----------------------------------------------------------------- sweep

  // After every inbox listing: decided senders' new mail goes to its place,
  // and what was sent to Bubble Up comes back when its time has come.
  property bool sweeping: false
  property Connections listWatch: Connections {
    target: host.account
    function onListRefreshed() {
      host.recount()
      Qt.callLater(host.sweep)
    }
  }

  function sweep() {
    if (!on || !available || sweeping || !account.ready) return
    if (!listingInbox) return
    var plan = Screener.sweepPlan(account.messages, ledger)
    var byFolder = {}
    for (var i = 0; i < plan.length; i++) {
      byFolder[plan[i].folder] = (byFolder[plan[i].folder] || []).concat([plan[i].id])
    }
    for (var key in byFolder) moveTo(byFolder[key], key)
    bringBackDue()
    if (!rulesPulled) pullRules()
  }

  function bringBackDue() {
    var due = Screener.due(ledger)
    var folder = labelIdFor("bubbleup")
    if (due.length === 0 || folder === "" || !account.backend) return
    sweeping = true
    account.backend.call("providers.resolve",
      { provider: account.providerId, operation: "labelQuery", value: Screener.place("bubbleup").folder },
      function(result, error) {
        var query = String((result || {}).value || "")
        if (error || query === "") { host.sweeping = false; return }
        host.account.api.listMessages(query, 100, "", function(page, failure) {
          var ids = page && Array.isArray(page.ids) ? page.ids : []
          if (failure || ids.length === 0) { host.sweeping = false; return }
          host.account.summarizedRead(ids, false, function(rows, readError) {
            host.sweeping = false
            if (readError || !Array.isArray(rows)) return
            var wanted = {}
            for (var d = 0; d < due.length; d++) wanted[due[d]] = true
            var back = rows.filter(function(r) { return wanted[String(r.messageId || "")] })
            var value = host.ledger
            for (var b = 0; b < due.length; b++) value = Screener.bubble(value, due[b], "")
            host.save(value)
            if (back.length === 0) return
            // Back at the top of the inbox, unread, as HEY does it.
            host.account.api.batchModify(back.map(function(r) { return String(r.id) }),
              ["INBOX", "UNREAD"], [folder], function(ignored, moveError) {
                if (moveError) { host.account.fail("Could not bring a message back: " + String(moveError)); return }
                host.account.note(back.length === 1 ? "A message bubbled up" : back.length + " messages bubbled up")
                host.account.refresh()
              })
          })
        })
      })
  }

  // ----------------------------------------------------------- server rules

  // An Outlook mailbox also sorts on the server: each place's senders become
  // an inbox rule, so mail reaches The Feed on the phone and while this app
  // is closed - see src/providers/outlook_rules.rs. Written through Graph,
  // or through Exchange Web Services for a mailbox whose tenant refuses Graph
  // (the one that reads its calendar that way). The sweep above keeps
  // running either way; a rule only gets there first.
  readonly property bool rulesReachable: available && account.providerId === "outlook"
    && !!account.backend && account.backend.ready && account.backend.apiVersion >= 6
  readonly property string rulesVia:
    String(account.imapSettings && account.imapSettings.calendar || "").toLowerCase() === "ews" ? "ews" : "graph"
  readonly property bool rulesAvailable: on && rulesReachable && rulesRefusal === ""
  // Why this mailbox's rules are not written, for the rest of the session or
  // until the consent they wait for is given: Outlook for Windows' own rules
  // in the way, Exchange refusing the token, Graph not consented. A network
  // failure is not remembered; the next decision tries again.
  property string rulesRefusal: ""
  property bool rulesPulled: false

  function rulesCode(error) { return String(error && error.message || error || "") }

  function rulesFailed(error) {
    var code = rulesCode(error)
    if (code === "auth_consent_required" && rulesVia === "graph" && account.auth) {
      rulesRefusal = code
      account.auth.rulesConsentNeeded = true
      account.note("To sort on the server too, choose Allow the Screener's rules in this mailbox's settings")
      return
    }
    var why = ({
      rules_outlook_blob: "Outlook for Windows keeps its own rules in this mailbox, so the Screener sorts only while this app is open",
      rules_auth_refused: "Exchange did not let the Screener write rules, so it sorts only while this app is open",
      rules_over_quota: "This mailbox has no room for more rules, so the Screener sorts only while this app is open",
      rules_too_many_senders: "Too many senders for one rule, so the Screener sorts only while this app is open"
    })[code]
    if (!why) return
    rulesRefusal = code
    account.note(why)
  }

  property Connections consentWatch: Connections {
    target: host.account.auth
    ignoreUnknownSignals: true
    function onRulesConsented() {
      host.rulesRefusal = ""
      host.rulesPulled = false
      host.pullRules()
    }
  }

  // Decisions arrive one key press at a time; they go out together.
  property Timer rulesTimer: Timer {
    interval: 3000
    onTriggered: host.syncRules()
  }
  function scheduleRules() { if (rulesAvailable) rulesTimer.restart() }

  // Once a session: what another machine decided, read off the rules, for
  // senders this one has never been asked about - then this machine's own
  // decisions written back.
  function pullRules() {
    if (!rulesAvailable || rulesPulled) return
    rulesPulled = true
    account.backend.call("outlook.screenerRules", { accountId: account.accountId, operation: "status", via: rulesVia },
      function(result, error) {
        if (!host) return
        if (error) { host.rulesPulled = false; host.rulesFailed(error); return }
        if (result && result.blob === true) { host.rulesFailed("rules_outlook_blob"); return }
        var adopted = Screener.adoptRules(host.ledger, result && result.places)
        if (JSON.stringify(adopted.senders) !== JSON.stringify(host.ledger.senders)) host.save(adopted)
        host.scheduleRules()
      })
  }

  function syncRules() {
    if (!rulesAvailable) return
    ensureFolders(function() {
      if (!host.rulesAvailable) return
      var lists = Screener.ruleLists(host.ledger)
      host.account.backend.call("outlook.screenerRules", {
        accountId: host.account.accountId, operation: "sync", via: host.rulesVia,
        rules: lists.rules, forget: lists.forget
      }, function(result, error) { if (host && error) host.rulesFailed(error) })
    })
  }

  // Switched off, the server stops sorting too: the three rules go, and
  // nothing else of the mailbox's.
  function clearRules() {
    rulesTimer.stop()
    if (!rulesReachable || rulesRefusal !== "") return
    rulesPulled = false
    account.backend.call("outlook.screenerRules", { accountId: account.accountId, operation: "clear", via: rulesVia },
      function(result, error) {
        if (host && error) host.account.fail("Could not remove the Screener's rules from Exchange")
      })
  }
}
