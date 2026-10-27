// Replays one request on the platform diagram, built from the events /api/ask returned: the hops and their
// times are the request's own. Only the pace is invented: every hop moves at the same speed, so a 40 ms
// tool call stays as visible as a 3 s model call. Text goes in with textContent only, as in app.js.
"use strict";

const Flow = (() => {
  const svg = document.getElementById("flow-diagram");
  const $ = sel => svg.querySelector(sel);
  const dot = $(".dot"), trails = [...svg.querySelectorAll(".trail")];
  const mark = $(".mark"), markText = $(".mark text");
  const label = document.getElementById("flow-label");
  const list = document.getElementById("flow-steps");
  const replay = document.getElementById("flow-replay");

  const SPEED = 0.2, MIN_MOVE = 450;  // px per ms in diagram units; shortest move in ms
  const DELAY = 1500;  // after Ask, let the form fold and the eye find the diagram before anything moves

  // Paths in diagram coordinates, following the drawn edges.
  const rev = pts => pts.slice().reverse();
  const P = {
    clientGw: [[202, 66], [280, 66]],
    gwPg: [[516, 66], [546, 66]],
    model: {
      "local-private": [[300, 88], [300, 104], [140, 104], [140, 214], [118, 214]],
      "cloud-general": [[330, 88], [330, 114], [198, 114], [198, 172]],
    },
    mcp: {
      finance: { gw: [[384, 88], [384, 140]], toEmb: [[384, 180], [384, 224]],
                 back: [[599, 224], [599, 196], [384, 196], [384, 180]] },
      hr: { gw: [[496, 88], [496, 108], [599, 108], [599, 140]], toEmb: [[599, 180], [599, 196], [384, 196], [384, 224]],
            back: [[599, 224], [599, 180]] },
    },
    embQd: [[384, 224], [384, 196], [599, 196], [599, 224]],
  };
  const MODEL = {
    "local-private": { box: "vllm", color: "teal", name: "vLLM on the lab GPU (local-private)" },
    "cloud-general": { box: "cohere", color: "amber", name: "the Cohere API (cloud-general)" },
  };
  const MCP_BOX = { finance: "kbf", hr: "khr" };
  // Where a refusal is drawn: just outside the gateway, on the way to what was refused.
  const STOP = {
    finance: { path: [[384, 88], [384, 98]], at: [384, 100], left: true },
    hr: { path: [[496, 88], [496, 98]], at: [496, 100], left: true },
    "local-private": { path: [[300, 88], [300, 96]], at: [300, 98], left: true },
    "cloud-general": { path: [[330, 88], [330, 98]], at: [330, 100] },
    gateway: { path: [[202, 66], [226, 66]], at: [236, 66], below: true },
  };

  const move = (pts, c) => ({ move: pts, c });
  const at = (box, ms, cls = "hot") => ({ at: box, ms, cls });
  const stop = (where, text) => [move(STOP[where].path, "bad"), { stop: STOP[where], text, ms: 1400 }];
  const deptOfTool = name => (/^kb_(finance|hr)-/.exec(name || "") || [])[1];
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

  function search(dept) {
    const p = P.mcp[dept], box = MCP_BOX[dept];
    return [move(p.gw, "blue"), at(box, 350), move(p.toEmb, "ink"), at("emb", 400), move(P.embQd, "ink"),
            at("qd", 450), move(p.back, "ink"), at(box, 300), move(rev(p.gw), "blue"), at("gw", 250)];
  }

  const firstScene = req => ({
    text: `The browser sends the question to web.py, which calls the LiteLLM gateway with the ${req.dept} key.`,
    acts: [move(P.clientGw, "ink"), at("gw", 350)],
  });
  const actMs = a => a.move ? Math.max(MIN_MOVE, len(a.move) / SPEED) : a.ms;

  // The request's events -> scenes: one line in the step list each, with the moves that draw it.
  function scenes(req, body) {
    const m = MODEL[req.model] || MODEL["local-private"];
    const out = [firstScene(req)];
    if (body.error) {
      out.push({ text: body.error, deny: true, acts: stop("gateway", "failed") });
      return out;
    }
    let calls = 0;
    for (const e of body.events) {
      switch (e.event) {
        case "tools":
          out.push({ text: `The gateway checks the key and shows it only its own tools: ${e.names.join(", ") || "none"}.`,
                     ms: e.ms, acts: [at("gw", 250), move(P.gwPg, "ink"), at("pg", 350), move(rev(P.gwPg), "ink"), at("gw", 250)] });
          break;
        case "model": {
          const path = P.model[req.model] || P.model["local-private"];
          const what = e.tool_calls ? `decides to call ${plural(e.tool_calls, "tool", "tools")}`
                     : calls ? "writes the answer from the passages" : "answers without calling a tool";
          out.push({ text: `The gateway sends the conversation to ${m.name}; the model ${what}.`, ms: e.ms,
                     acts: [move(path, m.color), at(m.box, 500), move(rev(path), m.color), at("gw", 250)] });
          break;
        }
        case "call": {
          calls++;
          const d = deptOfTool(e.target);
          if (!d) out.push({ text: `The model asked for ${e.name}, which this key cannot see; nothing was called.`,
                             deny: true, acts: stop(req.dept in STOP ? req.dept : "gateway", "not available") });
          else out.push({ text: `The gateway forwards the search to kb-${d} with that server's own token. It embeds the query, searches only kb_${d} and returns ${e.chars.toLocaleString("en-CA")} characters.`,
                          ms: e.ms, acts: search(d) });
          break;
        }
        case "direct": {
          const d = deptOfTool(req.tool);
          if (e.allowed) out.push({ text: `The gateway lets this key call ${req.tool}; kb-${d} searches kb_${d}.`, ms: e.ms, acts: search(d) },
                                  { text: `The passages go back to the browser: ${plural(e.sources.length, "source", "sources")}.`, ok: true,
                                    acts: [move(rev(P.clientGw), "ok"), at("client", 1200, "ok")] });
          else out.push({ text: `The gateway refuses: ${e.text}`, deny: true, acts: stop(d || "gateway", "refused") });
          break;
        }
        case "refused":
          out.push({ text: `The gateway refuses with HTTP ${e.status}. ${e.text}`, ms: e.ms, deny: true,
                     acts: stop(e.status === 403 ? req.model : "gateway", `HTTP ${e.status}`) });
          break;
        case "answer":
          out.push({ text: `The answer goes back to the browser with ${plural(e.sources.length, "retrieved source", "retrieved sources")}.`,
                     ok: true, acts: [move(rev(P.clientGw), "ok"), at("client", 1200, "ok")] });
          break;
        case "stopped":
          out.push({ text: `Stopped after ${e.rounds} tool rounds without an answer.`, deny: true, acts: stop("gateway", "stopped") });
          break;
      }
    }
    return out;
  }

  // --- drawing -------------------------------------------------------------------------------------------
  const len = pts => pts.slice(1).reduce((n, p, i) => n + Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]), 0);
  const ease = f => f < .5 ? 2 * f * f : 1 - (-2 * f + 2) ** 2 / 2;
  function pointAt(pts, f) {
    let d = f * len(pts);
    for (let i = 1; i < pts.length; i++) {
      const [x0, y0] = pts[i - 1], [x1, y1] = pts[i], seg = Math.hypot(x1 - x0, y1 - y0);
      if (d <= seg || i === pts.length - 1) {
        const k = seg ? Math.min(d / seg, 1) : 1;
        return [x0 + (x1 - x0) * k, y0 + (y1 - y0) * k];
      }
      d -= seg;
    }
  }

  function setBox(name, cls) {
    svg.querySelectorAll("[data-box]").forEach(b => b.classList.remove("hot", "ok", "deny", "wait"));
    if (name) $(`[data-box="${name}"]`).classList.add(cls);
  }
  function showMark(s) {
    mark.classList.toggle("on", !!s);
    if (!s) return;
    const { at: [x, y], left, below } = s.stop;
    mark.setAttribute("transform", `translate(${x},${y})`);
    markText.textContent = s.text;
    markText.setAttribute("x", below ? 0 : left ? -11 : 11);
    markText.setAttribute("y", below ? 20 : 3.5);
    markText.setAttribute("text-anchor", below ? "middle" : left ? "end" : "start");
  }
  function setTrails(history, c) {
    trails.forEach((t, i) => {
      const p = history[(i + 1) * 3 - 1];
      t.setAttribute("class", p ? `trail on c-${c}` : "trail");
      if (p) { t.setAttribute("cx", p[0]); t.setAttribute("cy", p[1]); }
    });
  }

  let raf = 0, timer = 0, last = null, pending = null;  // pending: when the first hop starts, until finish()

  function stopAnimation() {
    cancelAnimationFrame(raf);
    dot.setAttribute("class", "dot");
    setTrails([], "ink");
  }

  function renderList(sc) {
    list.replaceChildren(...sc.map(s => {
      const li = document.createElement("li");
      if (s.deny) li.classList.add("deny");
      if (s.ok) li.classList.add("good");
      li.append(s.text);
      if (s.ms !== undefined) {
        const t = document.createElement("span");
        t.className = "ms";
        t.textContent = `${Math.round(s.ms).toLocaleString("en-CA")} ms`;
        li.prepend(t);  // floated right, so it goes first
      }
      return li;
    }));
    return [...list.children];
  }

  // Plays the scenes from `offset` ms in, so a replay can pick up where waiting() left the dot.
  function run(sc, offset = 0) {
    if (offset) cancelAnimationFrame(raf);  // continuing: leave the dot where it is
    else stopAnimation();
    showMark(null);
    setBox(null);
    const items = renderList(sc);
    const timeline = [];
    let total = 0;
    sc.forEach((s, i) => s.acts.forEach(a => {
      const ms = actMs(a);
      timeline.push({ t0: total, t1: total + ms, i, a });
      total += ms;
    }));
    let start = performance.now() - offset, prevEntry = null, history = [];
    const frame = now => {
      const t = now - start;
      const e = timeline.find(x => t < x.t1);
      if (!e) {  // finished: keep the end state and mark every step done
        items.forEach(li => { li.classList.remove("now"); li.classList.add("done"); });
        dot.setAttribute("class", "dot");
        setTrails([], "ink");
        replay.hidden = false;
        return;
      }
      const { a, i } = e;
      if (e !== prevEntry) {
        items.forEach((li, k) => { li.classList.toggle("now", k === i); li.classList.toggle("done", k < i); });
        if (a.at) setBox(a.at, a.cls);
        else if (a.stop) setBox("gw", "deny");
        else setBox(null);
        showMark(a.stop ? a : null);
        dot.setAttribute("class", a.move ? `dot on c-${a.c}` : "dot");
        prevEntry = e;
      }
      let pos = null;
      if (a.move) {
        pos = pointAt(a.move, ease((t - e.t0) / (e.t1 - e.t0)));
        dot.setAttribute("cx", pos[0]);
        dot.setAttribute("cy", pos[1]);
      }
      history.unshift(pos);
      history.length = 15;
      setTrails(history, a.c || "ink");
      raf = requestAnimationFrame(frame);
    };
    raf = requestAnimationFrame(frame);
  }

  function heading(req, body) {
    const who = req.tool ? `${req.dept} → ${req.tool} (direct call)` : `${req.dept} · ${req.model}`;
    const parts = [`Replay: ${who}`];
    if (body.ms !== undefined) parts.push(`total ${Math.round(body.ms).toLocaleString("en-CA")} ms`);
    if (body.ref) parts.push(`log id ${body.ref}`);
    return parts.join(" · ");
  }

  return {
    // While /api/ask is running: the first hop, then the dot waits at the gateway. finish() continues
    // from there, so the browser-to-gateway hop is drawn once.
    waiting(req) {
      last = null;
      clearTimeout(timer);
      stopAnimation();
      showMark(null);
      setBox(null);
      pending = { start: performance.now() + DELAY };
      replay.hidden = true;
      label.textContent = `Waiting for the gateway: ${req.dept} · ${req.tool || req.model}`;
      const sc = [firstScene(req), { text: "Waiting for the answer. The first model call after a restart can take a while.",
                                     acts: [at("gw", Infinity, "wait")] }];
      renderList(sc);
      timer = setTimeout(() => run(sc), DELAY);
    },
    // The answer to the request waiting() started.
    finish(req, body) {
      const wait = pending ? pending.start - performance.now() : 0;
      if (wait > 0) {  // the answer came back during the pause: keep the pause, then play from the start
        label.textContent = heading(req, body);
        last = { req, body };
        clearTimeout(timer);
        timer = setTimeout(() => this.play(req, body), wait);
        return;
      }
      const sc = scenes(req, body);
      const offset = pending ? Math.min(-wait, sc[0].acts.reduce((n, a) => n + actMs(a), 0)) : 0;
      this.play(req, body, offset);
    },
    play(req, body, offset = 0) {
      last = { req, body };
      pending = null;
      clearTimeout(timer);
      replay.hidden = true;
      label.textContent = heading(req, body);
      run(scenes(req, body), offset);
    },
    replay() {
      if (last) this.play(last.req, last.body);
    },
  };
})();

document.getElementById("flow-replay").addEventListener("click", () => Flow.replay());
