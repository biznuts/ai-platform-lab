// Front end for demo/web.py. Builds every element with createElement/textContent: model output and
// retrieved text are untrusted, so nothing here is ever parsed as HTML.
"use strict";

// The scenarios from demo/run-demo.sh.
const EXAMPLES = [
  { label: "1 · Dept A, local model", dept: "dept-a", model: "local-private",
    question: "How many business days before the funder's deadline must an application reach the grants office?",
    expect: "cited answer" },
  { label: "2 · Dept B, cloud model", dept: "dept-b", model: "cloud-general",
    question: "What is the default penalty for late work?", expect: "cited answer" },
  { label: "3 · Dept B calls Dept A's tool", dept: "dept-b", model: "local-private", tool: "kb_dept_a-search_kb",
    question: "overhead rate on direct costs", expect: "refused" },
  { label: "3b · Dept A asks for the cloud model", dept: "dept-a", model: "cloud-general",
    question: "Summarise the rules for unfunded proposals.", expect: "HTTP 403" },
  { label: "4 · Planted prompt injection", dept: "dept-a", model: "local-private",
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

// The answer as text, with each [source_id] marked: "verified" if the tool really returned that id.
function answerNode(text, sources) {
  const p = el("p", "answer");
  const known = new Set(sources);
  let last = 0;
  // Models write "[01-x.md#0]" or "[source_id: 01-x.md#0]".
  for (const m of text.matchAll(/\[(?:source_id:\s*)?([^\[\]\s]+)\]/g)) {
    p.append(document.createTextNode(text.slice(last, m.index)));
    const ok = known.has(m[1]);
    const mark = el("mark", ok ? "cite" : "cite unverified", m[0]);
    mark.title = ok ? "Returned by the tool" : "Not among the retrieved passages";
    p.append(mark);
    last = m.index + m[0].length;
  }
  p.append(document.createTextNode(text.slice(last)));
  return p;
}

function chips(names, empty) {
  const box = el("div", "chips");
  if (!names.length) box.append(el("span", "muted", empty));
  for (const n of names) box.append(el("code", "chip", n));
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
  const meta = [res.seconds !== undefined ? `${res.seconds} s` : null, res.ref ? `ref ${res.ref}` : null];
  head.append(el("span", "muted", meta.filter(Boolean).join(" · ")));
  c.append(head, el("p", "question", req.question));

  if (body.error) {
    c.classList.add("bad");
    c.append(el("p", "outcome", `${body.error} Reference: ${body.ref || "none"}.`));
    return c;
  }
  for (const e of body.events) {
    switch (e.event) {
      case "tools":
        c.append(line("Tools this key sees", chips(e.names, "none")));
        break;
      case "call":
        c.append(line("Tool call", el("span", "", `model called ${e.name} → ${e.target} (${e.chars} characters)`)));
        break;
      case "direct":
        c.classList.add(e.allowed ? "ok" : "bad");
        c.append(el("p", "outcome", e.allowed ? "ALLOWED: the tool ran for this key." : `REFUSED: ${e.text}`));
        if (e.allowed) c.append(line("Sources returned", chips(e.sources, "none")));
        break;
      case "refused":
        c.classList.add("bad");
        c.append(el("p", "outcome", `REFUSED by the gateway: HTTP ${e.status}. ${e.text}`));
        break;
      case "answer":
        c.classList.add("ok");
        c.append(answerNode(e.text || "(no text)", e.sources));
        c.append(line("Retrieved sources", chips(e.sources, "none")));
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
