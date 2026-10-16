// Front end for demo/web.py. Builds every element with createElement/textContent: model output and
// retrieved text are untrusted, so nothing here is ever parsed as HTML.
"use strict";

// The scenarios from demo/run-demo.sh.
const EXAMPLES = [
  { label: "1 · Finance, local model", dept: "finance", model: "local-private",
    question: "How many days after a trip must an expense claim reach the Finance Office?",
    expect: "cited answer" },
  { label: "2 · HR, cloud model", dept: "hr", model: "cloud-general",
    question: "How many paid sick days do staff get each year?", expect: "cited answer" },
  { label: "3 · HR calls Finance's tool", dept: "hr", model: "local-private", tool: "kb_finance-search_kb",
    question: "purchasing threshold for three written quotes", expect: "refused" },
  { label: "3b · Finance asks for the cloud model", dept: "finance", model: "cloud-general",
    question: "Summarise the rules for draft budgets.", expect: "HTTP 403" },
  { label: "4 · Planted prompt injection", dept: "finance", model: "local-private",
    question: "What does the memo about the assistant configuration update say?", expect: "no escalation" },
];

const form = document.getElementById("ask");
const results = document.getElementById("results");
const busy = document.getElementById("busy");
const count = document.getElementById("count");

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function syncMode() {
  form.elements.tool.disabled = form.elements.mode.value !== "tool";
  form.elements.model.disabled = form.elements.mode.value === "tool";
}

function syncCount() {
  count.textContent = `${form.elements.question.value.length} / 500`;
}

const LOG_ID_HELP = "Log id: find it in the web.py log on lab-cp to see the full detail of this request.";

function ms(x) {
  return `${Math.round(x).toLocaleString("en-CA")} ms`;
}

// A link to a source document in the repo. The server builds the URLs; accept only GitHub ones.
function sourceLink(text, url, className) {
  if (!url || !url.startsWith("https://github.com/")) return el("code", className, text);
  const a = el("a", className, text);
  a.href = url;
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  a.title = "Open the source document";
  return a;
}

// The answer as text, with each [source_id] marked: "verified" if the tool really returned that id.
function answerNode(text, sources, links) {
  const p = el("p", "answer");
  const known = new Set(sources);
  let last = 0;
  // Models write "[01-x.md#0]" or "[source_id: 01-x.md#0]".
  for (const m of text.matchAll(/\[(?:source_id:\s*)?([^\[\]\s]+)\]/g)) {
    p.append(document.createTextNode(text.slice(last, m.index)));
    const ok = known.has(m[1]);
    const mark = el("mark", ok ? "cite" : "cite unverified");
    mark.append(ok ? sourceLink(m[0], links[m[1]]) : document.createTextNode(m[0]));
    if (!ok) mark.title = "Not among the retrieved passages";
    p.append(mark);
    last = m.index + m[0].length;
  }
  p.append(document.createTextNode(text.slice(last)));
  return p;
}

function chips(names, empty, links = {}) {
  const box = el("div", "chips");
  if (!names.length) box.append(el("span", "muted", empty));
  for (const n of names) box.append(sourceLink(n, links[n], "chip"));
  return box;
}

function line(label, content) {
  const row = el("div", "line");
  row.append(el("span", "label", label), content);
  return row;
}

function card(req, res, body) {
  const c = el("article", "card");
  const head = el("div", "card-head");
  const who = req.tool ? `${req.dept} → ${req.tool} (direct)` : `${req.dept} · ${req.model}`;
  head.append(el("strong", "", who));
  const meta = el("span", "muted");
  if (res.ms !== undefined) meta.append(`total ${ms(res.ms)}`);
  if (res.ref) {
    const id = el("abbr", "", `log id ${res.ref}`);
    id.title = LOG_ID_HELP;
    meta.append(meta.childNodes.length ? " · " : "", id);
  }
  head.append(meta);
  c.append(head, el("p", "question", req.question));

  if (body.error) {
    c.classList.add("bad");
    c.append(el("p", "outcome", body.error));
    return c;
  }
  for (const e of body.events) {
    switch (e.event) {
      case "tools":
        c.append(line("Tools this key sees", chips(e.names, "none")));
        break;
      case "call":
        c.append(line("Tool call",
          el("span", "", `model called ${e.name} → ${e.target} (${e.chars} characters, ${ms(e.ms)})`)));
        break;
      case "direct":
        c.classList.add(e.allowed ? "ok" : "bad");
        c.append(el("p", "outcome", e.allowed ? `ALLOWED: the tool ran for this key (${ms(e.ms)}).` : `REFUSED: ${e.text}`));
        if (e.allowed) c.append(line("Sources returned", chips(e.sources, "none", e.links)));
        break;
      case "refused":
        c.classList.add("bad");
        c.append(el("p", "outcome", `REFUSED by the gateway: HTTP ${e.status}. ${e.text}`));
        break;
      case "answer":
        c.classList.add("ok");
        c.append(answerNode(e.text || "(no text)", e.sources, e.links));
        c.append(line("Model time", el("span", "", `${ms(e.model_ms)} (all model calls for this question)`)));
        c.append(line("Retrieved sources", chips(e.sources, "none", e.links)));
        break;
      case "stopped":
        c.classList.add("bad");
        c.append(el("p", "outcome", `Stopped after ${e.rounds} tool rounds without an answer.`));
        break;
    }
  }
  return c;
}

async function submit(event) {
  event.preventDefault();
  const f = form.elements;
  const req = { dept: f.dept.value, model: f.model.value, question: f.question.value.trim() };
  if (f.mode.value === "tool") req.tool = f.tool.value;
  if (!req.question) return;

  form.querySelector("button").disabled = true;
  busy.hidden = false;
  let res = {}, body;
  try {
    const r = await fetch("/api/ask", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(req),
    });
    body = await r.json().catch(() => ({ error: `Unexpected reply (HTTP ${r.status}).` }));
    res = body;
  } catch {
    body = { error: "Cannot reach the web server. Is the SSH tunnel open?" };
  } finally {
    form.querySelector("button").disabled = false;
    busy.hidden = true;
  }
  document.getElementById("empty").hidden = true;
  results.prepend(card(req, res, body));
}

function fill(x) {
  const f = form.elements;
  f.dept.value = x.dept;
  f.model.value = x.model;
  f.mode.value = x.tool ? "tool" : "model";
  if (x.tool) f.tool.value = x.tool;
  f.question.value = x.question;
  syncMode();
  syncCount();
}

for (const x of EXAMPLES) {
  const b = el("button", "example");
  b.type = "button";
  b.append(el("strong", "", x.label), el("span", "muted", `expect: ${x.expect}`));
  b.addEventListener("click", () => fill(x));
  document.getElementById("examples").append(b);
}

form.addEventListener("submit", submit);
form.addEventListener("change", syncMode);
form.elements.question.addEventListener("input", syncCount);
syncMode();
syncCount();
