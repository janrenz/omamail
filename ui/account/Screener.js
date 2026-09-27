.pragma library

// The Screener and its places: ideas from HEY, over any mailbox that can hold
// folders or labels.
//
// A first-time sender waits in the Screener until somebody says where their
// mail goes: the Imbox for people, The Feed for what is read like a magazine,
// the Paper Trail for receipts and notifications that are kept rather than
// read - or out, to Screened Out. Reply Later is the provider's own flag or
// star, so it is flagged in every other client too. Set Aside and Bubble Up are
// folders; Bubble Up remembers when each message comes back.
//
// The places are real folders (IMAP, Outlook) or labels (Gmail): mail really
// moves, so the phone and the webmail see the same split. The decisions -
// which sender goes where, what comes back when - are the account's
// `screener` entry. That entry is per machine, like the rest of accounts.json;
// a second machine sees the mail already in its places and asks again only
// about senders it has never been told about.
//
// This file is the rules and nothing else: no request, no QML type. The
// object that runs them against an account is ScreenerHost.qml.

var PLACES = [
  { key: "imbox", label: "Imbox", icon: "inbox", inbox: true },
  { key: "screener", label: "The Screener", icon: "people", inbox: true },
  { key: "feed", label: "The Feed", icon: "feed", folder: "The Feed" },
  { key: "papertrail", label: "Paper Trail", icon: "archive", folder: "Paper Trail" },
  { key: "replylater", label: "Reply Later", icon: "reply", inbox: true },
  { key: "setaside", label: "Set Aside", icon: "pin", folder: "Set Aside" },
  { key: "bubbleup", label: "Bubble Up", icon: "clock", folder: "Bubble Up" },
  { key: "screenedout", label: "Screened Out", icon: "spam", folder: "Screened Out" }
]

// Where a decided sender's mail is moved. The Imbox is the inbox, so a
// sender let in is not moved at all.
var DECISIONS = { imbox: "", feed: "feed", papertrail: "papertrail", out: "screenedout" }

// The answers the Screener offers, in the order its keys number them.
var CHOICES = [
  { place: "imbox", label: "Imbox", key: "1" },
  { place: "feed", label: "The Feed", key: "2" },
  { place: "papertrail", label: "Paper Trail", key: "3" },
  { place: "out", label: "Screen out", key: "0" }
]

// Mail a poll may move at once: a sender screened out after years of
// newsletters would otherwise be a minute-long poll.
var SWEEP_CAP = 25

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function place(key) {
  for (var i = 0; i < PLACES.length; i++) if (PLACES[i].key === key) return PLACES[i]
  return null
}

function folderPlaces() {
  return PLACES.filter(function(p) { return !!p.folder })
}

function address(value) {
  var text = trimmed(value && typeof value === "object" ? value.email : value).toLowerCase()
  var angle = /<([^<>@\s]+@[^<>\s]+)>/.exec(text)
  if (angle) text = angle[1]
  return /^[^@\s]+@[^@\s]+$/.test(text) ? text : ""
}

function nowIso(nowMs) {
  return new Date(nowMs === undefined ? Date.now() : nowMs).toISOString()
}

// The account's entry as something the rules can rely on. It is written by
// this app, but it is also a file somebody can edit.
function normalize(raw, nowMs) {
  var value = raw && typeof raw === "object" ? raw : {}
  var out = { on: value.on === true, since: trimmed(value.since), senders: {}, bubbles: {} }
  if (out.on && out.since === "") out.since = nowIso(nowMs)
  var senders = value.senders && typeof value.senders === "object" ? value.senders : {}
  for (var who in senders) {
    var key = address(who)
    var decision = String(senders[who] || "")
    if (key !== "" && DECISIONS.hasOwnProperty(decision)) out.senders[key] = decision
  }
  var bubbles = value.bubbles && typeof value.bubbles === "object" ? value.bubbles : {}
  for (var id in bubbles) {
    var entry = bubbles[id] || {}
    var until = Date.parse(String(entry.until || ""))
    if (trimmed(id) !== "" && isFinite(until))
      out.bubbles[trimmed(id)] = { until: new Date(until).toISOString(), subject: trimmed(entry.subject).substring(0, 200) }
  }
  return out
}

function enabled(raw, nowMs) {
  var value = normalize(raw, nowMs)
  value.on = true
  if (value.since === "") value.since = nowIso(nowMs)
  return value
}

function decide(raw, sender, decision) {
  var value = normalize(raw)
  var who = address(sender)
  if (who === "") return value
  if (decision === "") delete value.senders[who]
  else if (DECISIONS.hasOwnProperty(decision)) value.senders[who] = decision
  return value
}

// Where an inbox row belongs: "imbox", "screener", or the place a decided
// sender goes and a sweep has not moved it to yet. An undecided sender is the
// Screener's only for mail that arrived after the Screener was switched on;
// older mail is the Imbox's, or switching it on would put ten years of
// senders in front of somebody at once.
function placeOf(row, raw) {
  var value = raw && raw.senders ? raw : normalize(raw)
  var who = address(row && row.from)
  var decision = who !== "" ? value.senders[who] : undefined
  if (decision === "imbox") return "imbox"
  if (decision !== undefined) return DECISIONS[decision]
  var date = Date.parse(String(row && row.date || ""))
  var since = Date.parse(value.since)
  if (!isFinite(date) || !isFinite(since)) return "imbox"
  return date < since ? "imbox" : "screener"
}

// The rows one inbox place shows. The Imbox leaves out the Screener and what
// waits for a reply; the Screener asks once per person; Reply Later is the
// flagged mail of everybody already let in.
function filter(rows, key, raw) {
  var list = Array.isArray(rows) ? rows : []
  var value = normalize(raw)
  var info = place(key)
  if (!value.on || !info || !info.inbox) return list
  var asked = {}
  var out = []
  // Senders from before the Screener was switched on, who have never been
  // decided either: their mail stays in the Imbox, and the Screener offers
  // them once each after the new ones, so an inbox that has always had its
  // newsletters can be sorted rather than only screened from now on.
  var earlier = []
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    var where = placeOf(row, value)
    if (key === "screener") {
      var who = address(row.from)
      if (who === "" || asked[who] || value.senders[who] !== undefined) continue
      if (where === "screener") { asked[who] = true; out.push(row) }
      else if (where === "imbox") earlier.push(row)
    } else if (key === "replylater") {
      if (row.starred === true && where !== "screener") out.push(row)
    } else if (where === "imbox" && row.starred !== true) {
      out.push(row)
    }
  }
  for (var e = 0; e < earlier.length; e++) {
    var sender = address(earlier[e].from)
    if (asked[sender]) continue
    asked[sender] = true
    out.push(earlier[e])
  }
  return out
}

// The inbox places of "All mailboxes": each row judged by its own mailbox's
// entry, `ledgers` keyed by account id. A mailbox without the Screener is all
// Imbox. The folder places are one mailbox's folders, so they are not here.
function filterMerged(rows, key, ledgers) {
  var list = Array.isArray(rows) ? rows : []
  var info = place(key)
  if (!info || !info.inbox) return list
  var groups = {}
  for (var i = 0; i < list.length; i++) {
    var owner = String(list[i].accountId || "")
    ;(groups[owner] = groups[owner] || []).push(list[i])
  }
  var kept = {}
  var screened = []
  for (var id in groups) {
    var raw = (ledgers || {})[id]
    var chosen = normalize(raw).on ? filter(groups[id], key, raw) : (key === "imbox" ? groups[id] : [])
    for (var c = 0; c < chosen.length; c++) kept[String(chosen[c].id)] = true
    if (key === "screener") screened = screened.concat(chosen)
  }
  // The Screener's own order is new senders before earlier ones; merged, the
  // new ones of every mailbox still come first.
  if (key === "screener") {
    var fresh = screened.filter(function(r) { return placeOf(r, (ledgers || {})[String(r.accountId || "")]) === "screener" })
    return fresh.concat(screened.filter(function(r) { return fresh.indexOf(r) < 0 }))
  }
  return list.filter(function(r) { return kept[String(r.id)] === true })
}

function inboxPlaces() {
  return PLACES.filter(function(p) { return !!p.inbox })
}

function counts(rows, raw) {
  var value = normalize(raw)
  var list = Array.isArray(rows) ? rows : []
  var out = { imbox: 0, screener: 0, replylater: 0 }
  if (!value.on) return out
  var waiting = {}
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    var where = placeOf(row, value)
    if (where === "screener") {
      var who = address(row.from)
      if (!waiting[who]) out.screener++
      waiting[who] = true
    } else if (row.starred === true) out.replylater++
    else if (where === "imbox" && row.unread === true) out.imbox++
  }
  return out
}

// Inbox rows whose sender has been decided to live somewhere else, newest
// first and capped - see SWEEP_CAP. Answers [{id, folder}] with the place key.
function sweepPlan(rows, raw) {
  var value = normalize(raw)
  if (!value.on) return []
  var list = (Array.isArray(rows) ? rows : []).slice()
  list.sort(function(a, b) { return String(b.date || "").localeCompare(String(a.date || "")) })
  var out = []
  for (var i = 0; i < list.length && out.length < SWEEP_CAP; i++) {
    var row = list[i]
    if (row.inInbox === false) continue
    var where = placeOf(row, value)
    if (where !== "imbox" && where !== "screener" && place(where) && place(where).folder)
      out.push({ id: String(row.id), folder: where })
  }
  return out
}

// The label or folder a place lives in, from the account's own label list:
// the top-level one with the place's name. Never guessed - one that is not
// there is created, and read back, before anything is moved.
function labelFor(labels, key) {
  var info = place(key)
  if (!info || !info.folder) return null
  var list = Array.isArray(labels) ? labels : []
  for (var i = 0; i < list.length; i++) {
    var label = list[i] || {}
    var name = trimmed(label.name || label.path)
    if (name.toLowerCase() === info.folder.toLowerCase()) return label
  }
  return null
}

function missingFolders(labels) {
  return folderPlaces().filter(function(p) { return !labelFor(labels, p.key) })
    .map(function(p) { return p.folder })
}

// Bubble Up. Keyed by the message's Message-ID, because a folder move gives
// an IMAP message a new id and this message is about to be moved twice.
function bubble(raw, messageId, until, subject) {
  var value = normalize(raw)
  var key = trimmed(messageId)
  var ms = Date.parse(String(until || ""))
  if (key === "") return value
  if (!isFinite(ms)) delete value.bubbles[key]
  else value.bubbles[key] = { until: new Date(ms).toISOString(), subject: trimmed(subject).substring(0, 200) }
  return value
}

function due(raw, nowMs) {
  var value = normalize(raw)
  var now = nowMs === undefined ? Date.now() : nowMs
  var out = []
  for (var key in value.bubbles)
    if (Date.parse(value.bubbles[key].until) <= now) out.push(key)
  return out
}

function bubbleUntil(raw, messageId) {
  var value = normalize(raw)
  var entry = value.bubbles[trimmed(messageId)]
  return entry ? entry.until : ""
}

// "Tomorrow" is eight in the morning; "next week" is Monday at eight.
function bubbleTime(choice, nowMs) {
  var at = new Date(nowMs === undefined ? Date.now() : nowMs)
  if (choice === "later") {
    at.setHours(at.getHours() + 3, 0, 0, 0)
  } else if (choice === "tomorrow") {
    at.setDate(at.getDate() + 1)
    at.setHours(8, 0, 0, 0)
  } else if (choice === "nextweek") {
    var ahead = (1 - at.getDay() + 7) % 7
    at.setDate(at.getDate() + (ahead === 0 ? 7 : ahead))
    at.setHours(8, 0, 0, 0)
  } else {
    return ""
  }
  return at.toISOString()
}

function two(n) { return (n < 10 ? "0" : "") + n }

// "tomorrow at 08:00", "today at 17:00", "Mon 5 Oct at 08:00".
function whenLabel(iso, nowMs) {
  var ms = Date.parse(String(iso || ""))
  if (!isFinite(ms)) return ""
  var at = new Date(ms)
  var now = new Date(nowMs === undefined ? Date.now() : nowMs)
  var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  var day = new Date(at.getFullYear(), at.getMonth(), at.getDate()).getTime()
  var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var date = day === today ? "today" : day === today + 86400000 ? "tomorrow"
    : names[at.getDay()] + " " + at.getDate() + " " + months[at.getMonth()]
  return date + " at " + two(at.getHours()) + ":" + two(at.getMinutes())
}
