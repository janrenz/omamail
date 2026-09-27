const assert = require("assert")
const { load } = require("./load")
const screener = load("account/Screener.js")
const accounts = load("account/Accounts.js")

const since = "2026-09-01T00:00:00.000Z"
const base = screener.enabled({ since: since })
const row = (id, email, date, extra) => Object.assign(
  { id: id, from: { email: email, name: email }, date: date, unread: true, starred: false, inInbox: true },
  extra || {})
const decided = [["friend@x.y", "imbox"], ["news@x.y", "feed"], ["shop@x.y", "papertrail"], ["spam@x.y", "out"]]
  .reduce((ledger, pair) => screener.decide(ledger, pair[0], pair[1]), base)

// Where a row belongs.
assert.strictEqual(screener.placeOf(row("a", "Friend@X.Y", "2026-09-10T00:00:00Z"), decided), "imbox")
assert.strictEqual(screener.placeOf(row("b", "news@x.y", "2026-09-10T00:00:00Z"), decided), "feed")
assert.strictEqual(screener.placeOf(row("c", "spam@x.y", "2026-09-10T00:00:00Z"), decided), "screenedout")
assert.strictEqual(screener.placeOf(row("d", "new@x.y", "2026-09-10T00:00:00Z"), decided), "screener",
  "an undecided sender since the switch waits in the Screener")
assert.strictEqual(screener.placeOf(row("e", "old@x.y", "2026-08-10T00:00:00Z"), decided), "imbox",
  "mail from before the switch is the Imbox's")

// The inbox places.
const rows = [
  row("seen", "friend@x.y", "2026-09-10T00:00:00Z", { unread: false }),
  row("wait1", "new@x.y", "2026-09-11T00:00:00Z"),
  row("wait2", "NEW@x.y", "2026-09-12T00:00:00Z"),
  row("flag", "friend@x.y", "2026-09-13T00:00:00Z", { starred: true }),
  row("news", "news@x.y", "2026-09-14T00:00:00Z")
]
const ids = (list) => JSON.parse(JSON.stringify(list)).map(r => r.id)
assert.deepStrictEqual(ids(screener.filter(rows, "imbox", decided)), ["seen"])
assert.deepStrictEqual(ids(screener.filter(rows, "screener", decided)), ["wait1"], "asked once per person")
{
  const withOld = rows.concat([row("old1", "letters@x.y", "2026-08-01T00:00:00Z"),
    row("old2", "letters@x.y", "2026-08-02T00:00:00Z"), row("oldfriend", "friend@x.y", "2026-08-03T00:00:00Z")])
  assert.deepStrictEqual(ids(screener.filter(withOld, "screener", decided)), ["wait1", "old1"],
    "undecided senders from before the switch follow, once each; decided ones never")
  assert.ok(ids(screener.filter(withOld, "imbox", decided)).indexOf("old1") >= 0,
    "while their mail stays in the Imbox")
}
assert.deepStrictEqual(ids(screener.filter(rows, "replylater", decided)), ["flag"])
assert.deepStrictEqual(ids(screener.filter(rows, "feed", decided)), ids(rows), "a folder place passes its rows through")
assert.deepStrictEqual(ids(screener.filter(rows, "imbox", {})), ids(rows), "off, nothing is filtered")
assert.deepStrictEqual(JSON.parse(JSON.stringify(screener.counts(rows, decided))), { imbox: 0, screener: 1, replylater: 1 })

// The sweep moves decided senders' inbox rows to their places, and only those.
const plan = JSON.parse(JSON.stringify(screener.sweepPlan(rows.concat([row("junk", "spam@x.y", "2026-09-15T00:00:00Z")]), decided)))
assert.deepStrictEqual(plan, [{ id: "junk", folder: "screenedout" }, { id: "news", folder: "feed" }])
const many = []
for (let i = 0; i < 40; i++) many.push(row("n" + i, "news@x.y", "2026-09-1" + (i % 10) + "T00:00:00Z"))
assert.strictEqual(screener.sweepPlan(many, decided).length, screener.SWEEP_CAP)

// A decision can be taken back.
assert.strictEqual(screener.placeOf(row("b", "news@x.y", "2026-09-10T00:00:00Z"),
  screener.decide(decided, "news@x.y", "")), "screener")

// A ledger somebody edited by hand.
const odd = screener.normalize({ on: true, since: since, senders: { "not an address": "feed", "a@b.c": "elsewhere", "d@e.f": "out" },
  bubbles: { "<m@x>": { until: "never" }, "<n@x>": { until: "2026-10-01T08:00:00Z", subject: "Hi" } } })
assert.deepStrictEqual(Object.keys(odd.senders), ["d@e.f"])
assert.deepStrictEqual(Object.keys(odd.bubbles), ["<n@x>"])

// Folders are found by name, never guessed.
const labels = [{ id: "The Feed", name: "The Feed" }, { id: "Label_7", name: "paper trail" }, { id: "INBOX", name: "INBOX" }]
assert.strictEqual(screener.labelFor(labels, "feed").id, "The Feed")
assert.strictEqual(screener.labelFor(labels, "papertrail").id, "Label_7", "case does not matter")
assert.strictEqual(screener.labelFor(labels, "imbox"), null)
assert.deepStrictEqual(JSON.parse(JSON.stringify(screener.missingFolders(labels))), ["Set Aside", "Bubble Up", "Screened Out"])

// Bubble Up.
const bubbled = screener.bubble(base, "<m@x>", "2026-09-20T08:00:00Z", "Later")
assert.deepStrictEqual(JSON.parse(JSON.stringify(screener.due(bubbled, Date.parse("2026-09-20T09:00:00Z")))), ["<m@x>"])
assert.strictEqual(screener.due(bubbled, Date.parse("2026-09-19T09:00:00Z")).length, 0)
assert.strictEqual(Object.keys(screener.bubble(bubbled, "<m@x>", "").bubbles).length, 0, "an empty time brings it back")
{
  const previous = process.env.TZ
  process.env.TZ = "Europe/Berlin"
  const wed = new Date(2026, 8, 30, 12, 0).getTime()
  assert.strictEqual(new Date(screener.bubbleTime("tomorrow", wed)).getHours(), 8)
  assert.strictEqual(new Date(screener.bubbleTime("nextweek", wed)).getDay(), 1)
  assert.strictEqual(screener.bubbleTime("never", wed), "")
  assert.strictEqual(screener.whenLabel(screener.bubbleTime("tomorrow", wed), wed), "tomorrow at 08:00")
  if (previous === undefined) delete process.env.TZ
  else process.env.TZ = previous
}

// The account keeps it.
{
  let list = accounts.add(accounts.emptyList ? accounts.emptyList() : { accounts: [] },
    { email: "me@example.org", provider: "imap" })
  const id = list.accounts[0].id
  list = accounts.setScreener(list, id, decided)
  assert.strictEqual(list.accounts[0].screener.senders["news@x.y"], "feed")
  assert.strictEqual(accounts.makeAccount({ email: "me@example.org" }).screener, null)
}

console.log("test_screener.js ok")
