//! The Screener's decisions as Exchange inbox rules, so a decided sender's
//! mail is sorted by the server - on the phone, in the web client, and while
//! this app is closed - rather than only when this app next lists the inbox.
//!
//! There are three rules at most, one per place a sender can be sent: The
//! Feed, the Paper Trail and Screened Out, each moving mail from its list of
//! senders into the folder of the same name. A rule is found again by its
//! display name, which only this module writes. Nothing a caller sends is
//! written into a request verbatim: the places are a fixed set, the folders
//! and names are this module's constants, and an address is checked and
//! escaped before it goes in.
//!
//! The rules are written through Microsoft Graph (`messageRules`, with
//! MailboxSettings.ReadWrite) unless the caller asks for Exchange Web Services
//! with `via: "ews"`, for a tenant that grants the mail client Exchange but
//! not Graph. Exchange Online stops serving EWS to other clients from October
//! 2026, so that is a stopgap; the rules, their names and the merge are the
//! same either way.
//!
//! Over EWS, a mailbox that has rules made by Outlook for Windows or Mac carries a
//! "rule blob" Exchange refuses to write past unless it is told to delete it,
//! and deleting it can take the desktop client's own rules with it. That is
//! never done here: such a mailbox answers `rules_outlook_blob`, and the app
//! keeps sorting on its own.

use quick_xml::{Reader, events::Event};
use reqwest::Client;
use serde_json::{Value, json};
use std::{sync::OnceLock, time::Duration};

const ENDPOINT: &str = "https://outlook.office365.com/EWS/Exchange.asmx";
const GRAPH: &str = "https://graph.microsoft.com/v1.0/me/mailFolders";
const LIMIT: usize = 4 * 1024 * 1024;
/// Senders per rule. Exchange keeps every rule of a mailbox in 256 KB; this
/// many addresses of ordinary length stay well inside it.
pub const MAX_SENDERS: usize = 1500;

/// (place key, folder, rule display name)
const PLACES: &[(&str, &str, &str)] = &[
    ("feed", "The Feed", "Screener: The Feed (omamail)"),
    (
        "papertrail",
        "Paper Trail",
        "Screener: Paper Trail (omamail)",
    ),
    (
        "screenedout",
        "Screened Out",
        "Screener: Screened Out (omamail)",
    ),
];

static CLIENT: OnceLock<Result<Client, &'static str>> = OnceLock::new();

fn client() -> Result<&'static Client, &'static str> {
    CLIENT
        .get_or_init(|| {
            Client::builder()
                .https_only(true)
                .hickory_dns(true)
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(20))
                .build()
                .map_err(|_| "rules_network_failed")
        })
        .as_ref()
        .map_err(|e| *e)
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// The mailbox, from `outlook:<address>`.
fn mailbox(account_id: &str) -> Result<&str, &'static str> {
    let address = account_id
        .strip_prefix("outlook:")
        .ok_or("invalid_params")?;
    if sender(address).is_none() {
        return Err("invalid_params");
    }
    Ok(address)
}

/// An address as a rule may hold one: one `@`, no space, no control
/// character, no markup, and of a length an address has.
fn sender(value: &str) -> Option<String> {
    // Refused rather than trimmed: a line break at the end is not an address
    // that happens to have one, it is a value nobody should have sent.
    let value = value.to_lowercase();
    let (local, domain) = value.split_once('@')?;
    if local.is_empty()
        || domain.is_empty()
        || domain.contains('@')
        || value.len() > 254
        || value
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || matches!(c, '<' | '>' | '"' | '\\'))
    {
        return None;
    }
    Some(value)
}

/// The senders the caller asked for, per place: checked, deduplicated, kept
/// in the order given, and refused past the ceiling rather than cut.
fn wanted(params: &Value) -> Result<Vec<(usize, Vec<String>)>, &'static str> {
    let rules = params["rules"].as_object().ok_or("invalid_params")?;
    if rules
        .keys()
        .any(|key| !PLACES.iter().any(|(place, ..)| place == key))
    {
        return Err("invalid_params");
    }
    let mut out = Vec::new();
    for (index, (place, ..)) in PLACES.iter().enumerate() {
        let list = match rules.get(*place) {
            None => Vec::new(),
            Some(value) => {
                let values = value.as_array().ok_or("invalid_params")?;
                if values.len() > MAX_SENDERS {
                    return Err("rules_too_many_senders");
                }
                let mut seen = Vec::new();
                for item in values {
                    let address = item.as_str().and_then(sender).ok_or("invalid_params")?;
                    if !seen.contains(&address) {
                        seen.push(address);
                    }
                }
                seen
            }
        };
        out.push((index, list));
    }
    Ok(out)
}

fn envelope(body: &str) -> String {
    format!(
        concat!(
            r#"<?xml version="1.0" encoding="utf-8"?>"#,
            r#"<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" "#,
            r#"xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" "#,
            r#"xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">"#,
            r#"<soap:Header><t:RequestServerVersion Version="Exchange2013"/></soap:Header>"#,
            r#"<soap:Body>{body}</soap:Body></soap:Envelope>"#
        ),
        body = body
    )
}

pub fn get_rules_body() -> String {
    envelope("<m:GetInboxRules/>")
}

pub fn find_folder_body(folder: &str) -> String {
    envelope(&format!(
        concat!(
            r#"<m:FindFolder Traversal="Shallow"><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape>"#,
            r#"<t:AdditionalProperties><t:FieldURI FieldURI="folder:DisplayName"/></t:AdditionalProperties>"#,
            r#"</m:FolderShape><m:Restriction><t:IsEqualTo><t:FieldURI FieldURI="folder:DisplayName"/>"#,
            r#"<t:FieldURIOrConstant><t:Constant Value="{name}"/></t:FieldURIOrConstant></t:IsEqualTo>"#,
            r#"</m:Restriction><m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/>"#,
            r#"</m:ParentFolderIds></m:FindFolder>"#
        ),
        name = escape(folder)
    ))
}

/// One rule operation. `existing` is (rule id, priority) of the rule already
/// there; `senders` empty means the rule goes.
pub enum Operation {
    Create {
        place: usize,
        priority: u32,
        folder_id: String,
        senders: Vec<String>,
    },
    Set {
        place: usize,
        rule_id: String,
        priority: u32,
        folder_id: String,
        senders: Vec<String>,
    },
    Delete {
        rule_id: String,
    },
}

fn rule_xml(
    rule_id: Option<&str>,
    place: usize,
    priority: u32,
    folder_id: &str,
    senders: &[String],
) -> String {
    let addresses: String = senders
        .iter()
        .map(|a| {
            format!(
                "<t:Address><t:EmailAddress>{}</t:EmailAddress></t:Address>",
                escape(a)
            )
        })
        .collect();
    format!(
        concat!(
            "<t:Rule>{id}<t:DisplayName>{name}</t:DisplayName><t:Priority>{priority}</t:Priority>",
            "<t:IsEnabled>true</t:IsEnabled><t:Conditions><t:FromAddresses>{addresses}</t:FromAddresses>",
            "</t:Conditions><t:Actions><t:MoveToFolder><t:FolderId Id=\"{folder}\"/></t:MoveToFolder>",
            "<t:StopProcessingRules>true</t:StopProcessingRules></t:Actions></t:Rule>"
        ),
        id = rule_id
            .map(|id| format!("<t:RuleId>{}</t:RuleId>", escape(id)))
            .unwrap_or_default(),
        name = escape(PLACES[place].2),
        priority = priority,
        addresses = addresses,
        folder = escape(folder_id)
    )
}

pub fn update_rules_body(operations: &[Operation]) -> String {
    let ops: String = operations
        .iter()
        .map(|op| match op {
            Operation::Create {
                place,
                priority,
                folder_id,
                senders,
            } => format!(
                "<t:CreateRuleOperation>{}</t:CreateRuleOperation>",
                rule_xml(None, *place, *priority, folder_id, senders)
            ),
            Operation::Set {
                place,
                rule_id,
                priority,
                folder_id,
                senders,
            } => format!(
                "<t:SetRuleOperation>{}</t:SetRuleOperation>",
                rule_xml(Some(rule_id), *place, *priority, folder_id, senders)
            ),
            Operation::Delete { rule_id } => format!(
                "<t:DeleteRuleOperation><t:RuleId>{}</t:RuleId></t:DeleteRuleOperation>",
                escape(rule_id)
            ),
        })
        .collect();
    // Never `true`: see the module comment.
    envelope(&format!(
        "<m:UpdateInboxRules><m:RemoveOutlookRuleBlob>false</m:RemoveOutlookRuleBlob><m:Operations>{ops}</m:Operations></m:UpdateInboxRules>"
    ))
}

fn local(name: &[u8]) -> &[u8] {
    name.rsplit(|b| *b == b':').next().unwrap_or(name)
}

/// What an answer says, read once: the first error code if any part of it is
/// an error, the rules it lists, whether a rule blob exists, and the folder
/// ids it names.
#[derive(Default, Debug, PartialEq)]
pub struct Answer {
    pub error: Option<String>,
    pub blob: bool,
    pub rules: Vec<Rule>,
    pub folders: Vec<String>,
}

/// An inbox rule as far as this module reads one: its senders only where it
/// is one of the three written here.
#[derive(Default, Debug, PartialEq, Clone)]
pub struct Rule {
    pub id: String,
    pub name: String,
    pub priority: u32,
    pub senders: Vec<String>,
}

pub fn read_answer(xml: &str) -> Result<Answer, &'static str> {
    let mut reader = Reader::from_str(xml);
    let mut answer = Answer::default();
    let mut path: Vec<Vec<u8>> = Vec::new();
    let mut text = String::new();
    let mut failed = false;
    let mut rule = Rule::default();
    loop {
        match reader.read_event() {
            Ok(Event::Start(tag)) => {
                let name = local(tag.name().as_ref()).to_vec();
                attributes(&tag, &name, &mut answer, &mut failed)?;
                if name.as_slice() == b"Rule" {
                    rule = Rule::default();
                }
                path.push(name);
                text.clear();
            }
            Ok(Event::Empty(tag)) => {
                let name = local(tag.name().as_ref()).to_vec();
                attributes(&tag, &name, &mut answer, &mut failed)?;
            }
            Ok(Event::Text(event)) => {
                text.push_str(&event.decode().map_err(|_| "rules_invalid_response")?);
            }
            Ok(Event::End(_)) => {
                let name = path.pop().unwrap_or_default();
                let value: String = text
                    .trim()
                    .chars()
                    .filter(|c| !c.is_control())
                    .take(1024)
                    .collect();
                let in_rule = path.last().map(Vec::as_slice) == Some(b"Rule");
                let in_from = path.iter().any(|p| p.as_slice() == b"FromAddresses")
                    && path.iter().any(|p| p.as_slice() == b"Rule");
                match name.as_slice() {
                    b"ResponseCode" if failed && answer.error.is_none() => {
                        answer.error = Some(value)
                    }
                    b"OutlookRuleBlobExists" => answer.blob = value == "true",
                    b"RuleId" if in_rule => rule.id = value,
                    b"DisplayName" if in_rule => rule.name = value,
                    b"Priority" if in_rule => rule.priority = value.parse().unwrap_or(0),
                    b"EmailAddress" if in_from && rule.senders.len() < 4 * MAX_SENDERS => {
                        if let Some(address) = sender(&value)
                            && !rule.senders.contains(&address)
                        {
                            rule.senders.push(address);
                        }
                    }
                    b"Rule" if answer.rules.len() < 1000 => {
                        let mut done = std::mem::take(&mut rule);
                        if !PLACES.iter().any(|p| p.2 == done.name) {
                            done.senders.clear();
                        }
                        answer.rules.push(done)
                    }
                    _ => {}
                }
                text.clear();
            }
            Ok(Event::Eof) => break,
            Err(_) => return Err("rules_invalid_response"),
            _ => {}
        }
    }
    if failed && answer.error.is_none() {
        answer.error = Some(String::new());
    }
    Ok(answer)
}

fn attributes(
    tag: &quick_xml::events::BytesStart<'_>,
    name: &[u8],
    answer: &mut Answer,
    failed: &mut bool,
) -> Result<(), &'static str> {
    if name == b"Fault" {
        return Err("rules_request_failed");
    }
    for attribute in tag.attributes().flatten() {
        let key = local(attribute.key.as_ref()).to_vec();
        let value = attribute
            .unescape_value()
            .map_err(|_| "rules_invalid_response")?;
        if key.as_slice() == b"ResponseClass" && value == "Error" {
            *failed = true;
        }
        if key.as_slice() == b"Id" && name == b"FolderId" && answer.folders.len() < 10 {
            answer.folders.push(value.chars().take(1024).collect());
        }
    }
    Ok(())
}

/// Each place's senders once this sync is done: what this machine decided,
/// then whatever the rule already held that this machine has not decided
/// otherwise. Another machine's decisions are kept that way - a sync adds
/// and takes away only what it knows about.
pub fn merged(
    wanted: &[(usize, Vec<String>)],
    forget: &[String],
    existing: &[Rule],
) -> Result<Vec<(usize, Vec<String>)>, &'static str> {
    let decided: Vec<&String> = wanted.iter().flat_map(|(_, list)| list.iter()).collect();
    let mut out = Vec::new();
    for (place, senders) in wanted {
        let mut list = senders.clone();
        if let Some(rule) = existing.iter().find(|r| r.name == PLACES[*place].2) {
            for address in &rule.senders {
                if !decided.contains(&address)
                    && !forget.contains(address)
                    && !list.contains(address)
                {
                    list.push(address.clone());
                }
            }
        }
        if list.len() > MAX_SENDERS {
            return Err("rules_too_many_senders");
        }
        out.push((*place, list));
    }
    Ok(out)
}

/// The operations that bring the mailbox's rules to `target`. A place with
/// senders needs its folder's id; one without has its rule removed; one
/// whose rule already says exactly this is left alone.
pub fn plan(
    target: &[(usize, Vec<String>)],
    existing: &[Rule],
    folder_ids: &[Option<String>],
) -> Result<Vec<Operation>, &'static str> {
    let mut next = existing.iter().map(|r| r.priority).max().unwrap_or(0) + 1;
    let mut ops = Vec::new();
    for (place, senders) in target {
        let found = existing.iter().find(|r| r.name == PLACES[*place].2);
        match (found, senders.is_empty()) {
            (Some(rule), true) => ops.push(Operation::Delete {
                rule_id: rule.id.clone(),
            }),
            (None, true) => {}
            (Some(rule), false) if &rule.senders == senders => {}
            (found, false) => {
                let folder_id = folder_ids[*place].clone().ok_or("rules_folder_missing")?;
                let senders = senders.clone();
                ops.push(match found {
                    Some(rule) => Operation::Set {
                        place: *place,
                        rule_id: rule.id.clone(),
                        priority: rule.priority.max(1),
                        folder_id,
                        senders,
                    },
                    None => {
                        next += 1;
                        Operation::Create {
                            place: *place,
                            priority: next - 1,
                            folder_id,
                            senders,
                        }
                    }
                });
            }
        }
    }
    Ok(ops)
}

async fn post(token: &str, mailbox: &str, body: String) -> Result<Answer, &'static str> {
    let mut response = client()?
        .post(ENDPOINT)
        .bearer_auth(token)
        .header("Content-Type", "text/xml; charset=utf-8")
        .header("X-AnchorMailbox", mailbox)
        .body(body)
        .send()
        .await
        .map_err(|_| "rules_network_failed")?;
    let status = response.status().as_u16();
    if status == 401 || status == 403 {
        return Err("rules_auth_refused");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "rules_network_failed")? {
        if chunk.len() > LIMIT - bytes.len() {
            return Err("rules_response_too_large");
        }
        bytes.extend_from_slice(&chunk);
    }
    // A SOAP fault arrives as 500 with a body worth reading; anything else
    // unsuccessful without one is a refusal.
    let text = String::from_utf8(bytes).map_err(|_| "rules_invalid_response")?;
    if !(200..300).contains(&status) && !text.contains("Envelope") {
        return Err("rules_request_failed");
    }
    read_answer(&text)
}

fn refused(answer: &Answer) -> Result<(), &'static str> {
    match answer.error.as_deref() {
        None => Ok(()),
        Some("ErrorOutlookRuleBlobExists") => Err("rules_outlook_blob"),
        Some("ErrorRulesOverQuota") => Err("rules_over_quota"),
        Some(_) => Err("rules_request_failed"),
    }
}

fn addresses(value: &Value) -> Result<Vec<String>, &'static str> {
    let Some(values) = value.as_array() else {
        return if value.is_null() {
            Ok(Vec::new())
        } else {
            Err("invalid_params")
        };
    };
    if values.len() > 4 * MAX_SENDERS {
        return Err("rules_too_many_senders");
    }
    values
        .iter()
        .map(|v| v.as_str().and_then(sender).ok_or("invalid_params"))
        .collect()
}

/// A rule as Graph writes it: the same conditions and actions as `rule_xml`.
pub fn graph_rule(place: usize, priority: u32, folder_id: &str, senders: &[String]) -> Value {
    json!({
        "displayName": PLACES[place].2,
        "sequence": priority,
        "isEnabled": true,
        "conditions": {
            "fromAddresses": senders
                .iter()
                .map(|a| json!({"emailAddress": {"address": a}}))
                .collect::<Vec<_>>(),
        },
        "actions": {"moveToFolder": folder_id, "stopProcessingRules": true},
    })
}

/// The inbox rules of a Graph listing, read the way `read_answer` reads
/// Exchange's: senders only of the three written here.
pub fn read_graph_rules(value: &Value) -> Result<Vec<Rule>, &'static str> {
    let list = value["value"].as_array().ok_or("rules_invalid_response")?;
    let mut rules = Vec::new();
    for item in list.iter().take(1000) {
        let clean = |v: &Value| -> String {
            v.as_str()
                .unwrap_or("")
                .chars()
                .filter(|c| !c.is_control())
                .take(1024)
                .collect()
        };
        let mut rule = Rule {
            id: clean(&item["id"]),
            name: clean(&item["displayName"]),
            priority: item["sequence"]
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .unwrap_or(0),
            senders: Vec::new(),
        };
        if rule.id.is_empty() {
            continue;
        }
        if PLACES.iter().any(|p| p.2 == rule.name) {
            let from = item["conditions"]["fromAddresses"].as_array();
            for entry in from.into_iter().flatten().take(4 * MAX_SENDERS) {
                if let Some(address) = entry["emailAddress"]["address"].as_str().and_then(sender)
                    && !rule.senders.contains(&address)
                {
                    rule.senders.push(address);
                }
            }
        }
        rules.push(rule);
    }
    Ok(rules)
}

fn graph_url(tail: &[&str]) -> Result<reqwest::Url, &'static str> {
    let mut url = reqwest::Url::parse(GRAPH).map_err(|_| "rules_request_failed")?;
    // Pushed as segments, so an id with a slash or a plus stays one segment.
    url.path_segments_mut()
        .map_err(|_| "rules_request_failed")?
        .extend(tail);
    Ok(url)
}

async fn graph(
    token: &str,
    method: reqwest::Method,
    url: reqwest::Url,
    body: Option<Value>,
) -> Result<Value, &'static str> {
    let mut request = client()?.request(method, url).bearer_auth(token);
    if let Some(body) = body {
        request = request
            .header("Content-Type", "application/json")
            .body(body.to_string());
    }
    let mut response = request.send().await.map_err(|_| "rules_network_failed")?;
    let status = response.status().as_u16();
    if status == 401 || status == 403 {
        return Err("rules_auth_refused");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "rules_network_failed")? {
        if chunk.len() > LIMIT - bytes.len() {
            return Err("rules_response_too_large");
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).map_err(|_| "rules_invalid_response")?
    };
    if !(200..300).contains(&status) {
        let code = value["error"]["code"].as_str().unwrap_or("");
        return Err(if code.contains("Quota") {
            "rules_over_quota"
        } else {
            "rules_request_failed"
        });
    }
    Ok(value)
}

/// Where the rules are read and written: Graph, or EWS for a tenant that
/// refuses Graph.
#[derive(Clone, Copy, PartialEq)]
enum Via {
    Graph,
    Ews,
}

async fn current(via: Via, token: &str, mailbox: &str) -> Result<Answer, &'static str> {
    match via {
        Via::Ews => {
            let answer = post(token, mailbox, get_rules_body()).await?;
            refused(&answer)?;
            Ok(answer)
        }
        Via::Graph => {
            let url = graph_url(&["inbox", "messageRules"])?;
            let value = graph(token, reqwest::Method::GET, url, None).await?;
            Ok(Answer {
                rules: read_graph_rules(&value)?,
                ..Answer::default()
            })
        }
    }
}

async fn folder(
    via: Via,
    token: &str,
    mailbox: &str,
    name: &str,
) -> Result<Option<String>, &'static str> {
    match via {
        Via::Ews => {
            let found = post(token, mailbox, find_folder_body(name)).await?;
            refused(&found)?;
            Ok(found.folders.first().cloned())
        }
        Via::Graph => {
            let mut url = reqwest::Url::parse(GRAPH).map_err(|_| "rules_request_failed")?;
            // `name` is one of PLACES' folder names: no quote to escape.
            url.query_pairs_mut()
                .append_pair("$filter", &format!("displayName eq '{name}'"))
                .append_pair("$select", "id,displayName");
            let value = graph(token, reqwest::Method::GET, url, None).await?;
            Ok(value["value"]
                .as_array()
                .and_then(|list| list.first())
                .and_then(|f| f["id"].as_str())
                .filter(|id| !id.is_empty() && id.len() <= 1024)
                .map(str::to_owned))
        }
    }
}

async fn apply(
    via: Via,
    token: &str,
    mailbox: &str,
    ops: &[Operation],
) -> Result<(), &'static str> {
    if via == Via::Ews {
        let done = post(token, mailbox, update_rules_body(ops)).await?;
        return refused(&done);
    }
    for op in ops {
        let (method, url, body) = match op {
            Operation::Create {
                place,
                priority,
                folder_id,
                senders,
            } => (
                reqwest::Method::POST,
                graph_url(&["inbox", "messageRules"])?,
                Some(graph_rule(*place, *priority, folder_id, senders)),
            ),
            Operation::Set {
                place,
                rule_id,
                priority,
                folder_id,
                senders,
            } => (
                reqwest::Method::PATCH,
                graph_url(&["inbox", "messageRules", rule_id])?,
                Some(graph_rule(*place, *priority, folder_id, senders)),
            ),
            Operation::Delete { rule_id } => (
                reqwest::Method::DELETE,
                graph_url(&["inbox", "messageRules", rule_id])?,
                None,
            ),
        };
        graph(token, method, url, body).await?;
    }
    Ok(())
}

/// `outlook.screenerRules`, over Graph unless `via` is `"ews"`:
/// - `{accountId, operation: "status"}` answers whether a rule blob is in
///   the way (EWS only) and the senders each of the three rules holds;
/// - `{accountId, operation: "sync", rules: {feed, papertrail, screenedout},
///   forget: [...]}` merges this machine's decisions into them - see
///   `merged` - with `forget` naming senders decided to stay in the inbox;
/// - `{accountId, operation: "clear"}` removes the three and nothing else.
pub async fn call(params: &Value) -> Result<Value, &'static str> {
    let account = params["accountId"].as_str().ok_or("invalid_params")?;
    let mailbox = mailbox(account)?.to_owned();
    let via = match params["via"].as_str() {
        None | Some("graph") => Via::Graph,
        Some("ews") => Via::Ews,
        Some(_) => return Err("invalid_params"),
    };
    let operation = params["operation"].as_str().ok_or("invalid_params")?;
    let wanted = match operation {
        "status" => None,
        "sync" => Some((wanted(params)?, addresses(&params["forget"])?)),
        "clear" => Some((
            (0..PLACES.len()).map(|i| (i, Vec::new())).collect(),
            Vec::new(),
        )),
        _ => return Err("invalid_params"),
    };
    let resource = if via == Via::Ews { "ews" } else { "rules" };
    let token = crate::auth::access_token("outlook", account, resource).await?;
    let current = current(via, &token, &mailbox).await?;
    let Some((wanted, forget)) = wanted else {
        let mut places = serde_json::Map::new();
        for (key, _, name) in PLACES {
            let senders = current
                .rules
                .iter()
                .find(|r| r.name == *name)
                .map(|r| r.senders.clone());
            places.insert((*key).into(), json!(senders.unwrap_or_default()));
        }
        return Ok(json!({"blob": current.blob, "places": places}));
    };
    let target = if operation == "clear" {
        wanted
    } else {
        merged(&wanted, &forget, &current.rules)?
    };
    let mut folder_ids: Vec<Option<String>> = vec![None; PLACES.len()];
    for (place, senders) in &target {
        let unchanged = current
            .rules
            .iter()
            .any(|r| r.name == PLACES[*place].2 && &r.senders == senders);
        if senders.is_empty() || unchanged {
            continue;
        }
        folder_ids[*place] = folder(via, &token, &mailbox, PLACES[*place].1).await?;
    }
    let ops = plan(&target, &current.rules, &folder_ids)?;
    if ops.is_empty() {
        return Ok(json!({"changed": 0}));
    }
    if current.blob {
        return Err("rules_outlook_blob");
    }
    apply(via, &token, &mailbox, &ops).await?;
    Ok(json!({"changed": ops.len()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(id: &str, name: &str, priority: u32, senders: &[&str]) -> Rule {
        Rule {
            id: id.into(),
            name: name.into(),
            priority,
            senders: senders.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn list(values: &[&str]) -> Vec<String> {
        values.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn senders_are_checked_and_deduplicated() {
        let params =
            json!({"rules": {"feed": ["News@Example.org", "news@example.org", "b@example.org"]}});
        let wanted = wanted(&params).unwrap();
        assert_eq!(wanted[0].1, vec!["news@example.org", "b@example.org"]);
        assert!(wanted[1].1.is_empty() && wanted[2].1.is_empty());
        for bad in ["a b@x.y", "x", "a@b@c", "<a@b>", "a@b\"", "", "a@b\n"] {
            assert!(
                super::wanted(&json!({"rules": {"feed": [bad]}})).is_err(),
                "{bad}"
            );
            assert!(addresses(&json!([bad])).is_err(), "{bad}");
        }
        assert!(
            super::wanted(&json!({"rules": {"inbox": []}})).is_err(),
            "only the three places"
        );
        let many: Vec<String> = (0..MAX_SENDERS + 1).map(|i| format!("a{i}@x.y")).collect();
        assert_eq!(
            super::wanted(&json!({"rules": {"feed": many}})).err(),
            Some("rules_too_many_senders")
        );
        assert!(mailbox("outlook:a b@x.y").is_err() && mailbox("imap:a@x.y").is_err());
    }

    #[test]
    fn a_rule_moves_its_senders_and_stops_and_never_drops_the_outlook_blob() {
        let body = update_rules_body(&[Operation::Create {
            place: 1,
            priority: 4,
            folder_id: "AQMk=".into(),
            senders: list(&["shop&co@example.org"]),
        }]);
        assert!(body.contains("<m:RemoveOutlookRuleBlob>false</m:RemoveOutlookRuleBlob>"));
        assert!(!body.contains("RemoveOutlookRuleBlob>true"));
        assert!(body.contains("<t:DisplayName>Screener: Paper Trail (omamail)</t:DisplayName>"));
        assert!(body.contains("<t:Priority>4</t:Priority>"));
        assert!(body.contains("<t:EmailAddress>shop&amp;co@example.org</t:EmailAddress>"));
        assert!(body.contains(
            r#"<t:MoveToFolder><t:FolderId Id="AQMk="/></t:MoveToFolder><t:StopProcessingRules>true"#
        ));
        assert!(find_folder_body("Paper Trail").contains(r#"<t:Constant Value="Paper Trail"/>"#));
    }

    #[test]
    fn a_sync_keeps_what_another_machine_decided() {
        let existing = vec![rule(
            "r2",
            "Screener: The Feed (omamail)",
            5,
            &["old@x.y", "moved@x.y", "back@x.y"],
        )];
        let wanted = vec![
            (0, list(&["news@x.y"])),
            (1, list(&["moved@x.y"])),
            (2, vec![]),
        ];
        let target = merged(&wanted, &list(&["back@x.y"]), &existing).unwrap();
        assert_eq!(
            target[0].1,
            list(&["news@x.y", "old@x.y"]),
            "kept: old@ (not decided here); gone: moved@ (decided elsewhere) and back@ (let in)"
        );
        assert_eq!(target[1].1, list(&["moved@x.y"]));
        assert!(target[2].1.is_empty());
    }

    #[test]
    fn the_plan_creates_updates_and_removes_only_its_own_rules() {
        let existing = vec![
            rule("r1", "Mine from Outlook", 3, &[]),
            rule("r2", "Screener: The Feed (omamail)", 5, &["old@x.y"]),
            rule("r3", "Screener: Screened Out (omamail)", 6, &["spam@x.y"]),
        ];
        let target = vec![
            (0, list(&["news@x.y"])),
            (1, list(&["shop@x.y"])),
            (2, vec![]),
        ];
        let folders = vec![Some("F".to_string()), Some("P".to_string()), None];
        let ops = plan(&target, &existing, &folders).unwrap();
        assert!(matches!(&ops[0], Operation::Set { rule_id, priority: 5, .. } if rule_id == "r2"));
        assert!(matches!(
            &ops[1],
            Operation::Create {
                place: 1,
                priority: 7,
                ..
            }
        ));
        assert!(matches!(&ops[2], Operation::Delete { rule_id } if rule_id == "r3"));
        assert_eq!(
            ops.len(),
            3,
            "a rule this module did not write is never touched"
        );
        let same = plan(&[(0, list(&["old@x.y"]))], &existing, &[None, None, None]).unwrap();
        assert!(
            same.is_empty(),
            "a rule that already says this is not written again"
        );
        let missing = plan(&[(0, list(&["a@x.y"]))], &[], &[None, None, None]);
        assert_eq!(missing.err(), Some("rules_folder_missing"));
    }

    #[test]
    fn answers_are_read_for_rules_senders_blob_folders_and_errors() {
        let rules = concat!(
            r#"<s:Envelope xmlns:s="s"><s:Body><m:GetInboxRulesResponse xmlns:m="m" xmlns:t="t" ResponseClass="Success">"#,
            r#"<m:ResponseCode>NoError</m:ResponseCode><m:OutlookRuleBlobExists>true</m:OutlookRuleBlobExists>"#,
            r#"<m:InboxRules><t:Rule><t:RuleId>r2</t:RuleId><t:DisplayName>Screener: The Feed (omamail)</t:DisplayName>"#,
            r#"<t:Priority>5</t:Priority><t:IsEnabled>true</t:IsEnabled><t:Conditions><t:FromAddresses><t:Address>"#,
            r#"<t:EmailAddress>News@X.y</t:EmailAddress><t:DisplayName>not the rule's</t:DisplayName></t:Address>"#,
            r#"<t:Address><t:EmailAddress>not an address</t:EmailAddress></t:Address>"#,
            r#"</t:FromAddresses></t:Conditions></t:Rule>"#,
            r#"<t:Rule><t:RuleId>r9</t:RuleId><t:DisplayName>Somebody else's</t:DisplayName><t:Priority>1</t:Priority>"#,
            r#"<t:Conditions><t:FromAddresses><t:Address><t:EmailAddress>boss@x.y</t:EmailAddress></t:Address>"#,
            r#"</t:FromAddresses></t:Conditions></t:Rule></m:InboxRules>"#,
            r#"</m:GetInboxRulesResponse></s:Body></s:Envelope>"#
        );
        let answer = read_answer(rules).unwrap();
        assert!(answer.blob);
        assert_eq!(
            answer.rules[0],
            rule("r2", "Screener: The Feed (omamail)", 5, &["news@x.y"])
        );
        assert!(
            answer.rules[1].senders.is_empty(),
            "another rule's senders are never read"
        );
        assert_eq!(answer.error, None);
        let folder = r#"<s:Envelope xmlns:s="s"><s:Body><m:FindFolderResponseMessage ResponseClass="Success"><t:Folder><t:FolderId Id="F1" ChangeKey="c"/></t:Folder></m:FindFolderResponseMessage></s:Body></s:Envelope>"#;
        assert_eq!(read_answer(folder).unwrap().folders, vec!["F1"]);
        let error = r#"<s:Envelope xmlns:s="s"><s:Body><m:UpdateInboxRulesResponse ResponseClass="Error"><m:ResponseCode>ErrorOutlookRuleBlobExists</m:ResponseCode></m:UpdateInboxRulesResponse></s:Body></s:Envelope>"#;
        assert_eq!(
            refused(&read_answer(error).unwrap()),
            Err("rules_outlook_blob")
        );
        let fault = r#"<s:Envelope xmlns:s="s"><s:Body><s:Fault><faultcode>x</faultcode></s:Fault></s:Body></s:Envelope>"#;
        assert_eq!(read_answer(fault), Err("rules_request_failed"));
    }

    #[test]
    fn graph_rules_are_written_and_read_like_exchange_ones() {
        let body = graph_rule(0, 3, "AAMk=", &list(&["a@x.y", "b@x.y"]));
        assert_eq!(body["displayName"], "Screener: The Feed (omamail)");
        assert_eq!(body["sequence"], 3);
        assert_eq!(body["actions"]["moveToFolder"], "AAMk=");
        assert_eq!(body["actions"]["stopProcessingRules"], true);
        assert_eq!(body["conditions"]["fromAddresses"][1]["emailAddress"]["address"], "b@x.y");
        assert!(body["actions"].get("delete").is_none() && body["actions"].get("forwardTo").is_none());

        let listing = json!({"value": [
            {"id": "r1", "displayName": "Screener: Paper Trail (omamail)", "sequence": 2,
             "conditions": {"fromAddresses": [
                {"emailAddress": {"address": "Bill@X.Y"}},
                {"emailAddress": {"address": "bill@x.y"}},
                {"emailAddress": {"address": "not an address"}}]}},
            {"id": "r2", "displayName": "Someone else's", "sequence": 1,
             "conditions": {"fromAddresses": [{"emailAddress": {"address": "boss@x.y"}}]}},
            {"displayName": "no id"}
        ]});
        let rules = read_graph_rules(&listing).unwrap();
        assert_eq!(rules.len(), 2);
        assert_eq!(rules[0], rule("r1", "Screener: Paper Trail (omamail)", 2, &["bill@x.y"]));
        assert!(rules[1].senders.is_empty(), "another rule's senders are not read");
        assert_eq!(read_graph_rules(&json!({"error": {}})), Err("rules_invalid_response"));
    }

    #[test]
    fn a_graph_rule_id_stays_one_path_segment() {
        let url = graph_url(&["inbox", "messageRules", "AQ/+a=="]).unwrap();
        assert_eq!(url.host_str(), Some("graph.microsoft.com"));
        assert_eq!(url.path(), "/v1.0/me/mailFolders/inbox/messageRules/AQ%2F+a==");
    }
}
