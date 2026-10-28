/// The clinician page, served by the phone.
///
/// One self-contained document: no CDN, no fonts, no libraries. A clinic
/// network may have no route to the internet, and the whole point of this
/// bridge is that it works on a bare LAN with nothing deployed. Canvas rather
/// than a charting library for the same reason.
///
/// It is strictly read-only. A viewer cannot start a set or change a
/// parameter — those decisions stay with whoever is standing next to the
/// patient holding the phone.
library;

/// Served at `/`. The WebSocket feed is at `/ws`, a one-shot snapshot at
/// `/snapshot.json`.
const String clinicianPageHtml = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RehabSense — live session</title>
<style>
  :root {
    --bg: #101418;
    --surface: #181d23;
    --surface-high: #212830;
    --divider: #2c343d;
    --ink: #f2f5f7;
    --ink-soft: #a7b2bd;
    --ink-faint: #6b7681;
    --actual: #4fc3f7;
    --muscle: #ff8a65;
    --good: #66bb6a;
    --warn: #ffb74d;
    --bad: #ef5350;
    --hold: #ba68c8;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
          Helvetica, Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 1180px; margin: 0 auto; padding: 20px 16px 48px; }

  header { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap;
           margin-bottom: 18px; }
  h1 { font-size: 22px; font-weight: 500; margin: 0; letter-spacing: -0.2px; }
  .sub { color: var(--ink-faint); font-size: 13px; }

  .pill { display: inline-flex; align-items: center; gap: 7px;
          padding: 5px 11px; border-radius: 999px; font-size: 12px;
          font-weight: 600; letter-spacing: 0.4px; text-transform: uppercase;
          background: var(--surface-high); color: var(--ink-soft); }
  .dot { width: 8px; height: 8px; border-radius: 50%;
         background: var(--ink-faint); }
  .pill.live .dot { background: var(--good);
                    box-shadow: 0 0 0 3px rgba(102,187,106,.18); }
  .pill.stale .dot { background: var(--warn); }
  .pill.down .dot { background: var(--bad); }

  .tiles { display: grid; gap: 10px; margin-bottom: 16px;
           grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); }
  .tile { background: var(--surface); border-radius: 12px; padding: 13px 15px; }
  .tile .k { font-size: 11px; font-weight: 600; letter-spacing: .8px;
             text-transform: uppercase; color: var(--ink-faint); }
  .tile .v { font-size: 27px; font-weight: 300; margin-top: 4px;
             font-variant-numeric: tabular-nums; line-height: 1.1; }
  .tile .n { font-size: 12px; color: var(--ink-faint); margin-top: 2px; }
  .v.good { color: var(--good); } .v.warn { color: var(--warn); }
  .v.bad { color: var(--bad); }

  .card { background: var(--surface); border-radius: 14px; padding: 15px;
          margin-bottom: 16px; }
  .card h2 { font-size: 12px; font-weight: 600; letter-spacing: .8px;
             text-transform: uppercase; color: var(--ink-faint);
             margin: 0 0 4px; }
  .card .hint { font-size: 12.5px; color: var(--ink-faint);
                margin: 0 0 12px; }
  canvas { width: 100%; display: block; border-radius: 8px;
           background: #0c1014; }

  .legend { display: flex; gap: 16px; flex-wrap: wrap; font-size: 12px;
            color: var(--ink-soft); margin-top: 9px; }
  .legend i { display: inline-block; width: 18px; height: 3px;
              border-radius: 2px; vertical-align: middle;
              margin-right: 6px; }

  .cols { display: grid; gap: 16px; grid-template-columns: 1fr; }
  @media (min-width: 880px) { .cols { grid-template-columns: 1.15fr .85fr; } }

  table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
  th { text-align: left; font-size: 11px; letter-spacing: .6px;
       text-transform: uppercase; color: var(--ink-faint);
       font-weight: 600; padding: 0 8px 8px 0; }
  td { padding: 7px 8px 7px 0; border-top: 1px solid var(--divider);
       font-variant-numeric: tabular-nums; }
  tr.flagged td:first-child { box-shadow: inset 2px 0 0 var(--bad); }
  .score { font-weight: 600; }

  .log { max-height: 340px; overflow-y: auto; }
  .ev { display: flex; gap: 10px; padding: 7px 0;
        border-top: 1px solid var(--divider); font-size: 13.5px; }
  .ev:first-child { border-top: 0; }
  .ev time { color: var(--ink-faint); font-variant-numeric: tabular-nums;
             flex: 0 0 62px; font-size: 12.5px; }
  .ev .what { flex: 1; }
  .ev .detail { color: var(--ink-faint); font-size: 12.5px; }
  .ev.concerning .what { color: var(--warn); }

  .empty { color: var(--ink-faint); font-size: 13px; padding: 14px 0; }
  .note { background: var(--surface-high); border-radius: 10px;
          padding: 11px 13px; font-size: 12.5px; color: var(--ink-soft);
          margin-top: 14px; }
</style>
</head>
<body>
<div class="wrap">

  <header>
    <h1>RehabSense</h1>
    <span class="sub" id="devname">live session</span>
    <span style="flex:1"></span>
    <span class="pill down" id="conn"><span class="dot"></span><span
      id="connText">connecting</span></span>
  </header>

  <div class="tiles">
    <div class="tile"><div class="k">Reps</div>
      <div class="v" id="reps">0</div>
      <div class="n" id="repsNote">of 20</div></div>
    <div class="tile"><div class="k">Elbow</div>
      <div class="v" id="angle">—</div>
      <div class="n" id="angleNote">peak 88&deg;</div></div>
    <div class="tile"><div class="k">Biceps effort</div>
      <div class="v" id="effort">—</div>
      <div class="n" id="effortNote">% of maximum</div></div>
    <div class="tile"><div class="k">Mean score</div>
      <div class="v" id="score">—</div>
      <div class="n" id="scoreNote">device-graded</div></div>
    <div class="tile"><div class="k">Phase</div>
      <div class="v" id="phase" style="font-size:20px">—</div>
      <div class="n" id="phaseNote">&nbsp;</div></div>
    <div class="tile"><div class="k">Fatigue</div>
      <div class="v" id="fatigue" style="font-size:20px">—</div>
      <div class="n">median frequency trend</div></div>
  </div>

  <div class="card">
    <h2>Elbow angle</h2>
    <p class="hint">Last 30 seconds. The band is where a repetition lives: it
      starts above the start angle and must pass the peak criterion, which is
      80% of the therapist-set target rather than the target itself.</p>
    <canvas id="angleChart" height="200"></canvas>
    <div class="legend">
      <span><i style="background:var(--actual)"></i>Elbow angle</span>
      <span><i style="background:rgba(102,187,106,.45)"></i>Rep band</span>
      <span><i style="background:var(--good)"></i>Peak criterion</span>
      <span><i style="background:var(--ink-faint)"></i>Target angle</span>
    </div>
  </div>

  <div class="card">
    <h2>Biceps effort</h2>
    <p class="hint">Percentage of the calibrated maximum, on the same time
      axis. It should rise through each curl and fall back near zero at rest.
      Shaded where the device considers the muscle active — a repetition
      cannot start without it, which is what rejects a passively swung arm.</p>
    <canvas id="emgChart" height="150"></canvas>
    <div class="legend">
      <span><i style="background:var(--muscle)"></i>Effort, %MVC</span>
      <span><i style="background:rgba(255,138,101,.22)"></i>Muscle active</span>
    </div>
  </div>

  <div class="cols">
    <div class="card">
      <h2>Repetitions</h2>
      <p class="hint">As the device graded them. Empty until the firmware
        emits per-repetition results; the counter above still advances.</p>
      <div id="repTableWrap"><div class="empty">No repetitions yet.</div></div>
    </div>

    <div class="card">
      <h2>Session log</h2>
      <p class="hint">Every event the sleeve reported, newest first.</p>
      <div class="log" id="log"><div class="empty">Nothing yet.</div></div>
    </div>
  </div>

  <div class="card">
    <h2>Device</h2>
    <div id="devinfo" class="empty">Waiting for status.</div>
    <div class="note">
      This view is read-only and is served by the phone on your local network.
      The full session record &mdash; raw EMG and IMU at full rate &mdash; is
      not streamed here; it is transferred off the sleeve over Wi-Fi after the
      set, because the sleeve has one radio and the live link takes priority.
    </div>
  </div>

</div>

<script>
(function () {
  "use strict";

  var MAXPTS = 600;          // 30 s at 20 Hz
  var trace = [];            // {t, angle, env, on}
  var reps = [];
  var log = [];
  var cfg = { target: 110, peak: 88, start: 15, finish: 10, repTarget: 20,
              tempoMin: 1.5, tempoMax: 3.5 };
  var status = null, calib = null, device = null;
  var lastFrameAt = 0;

  // ---- connection ------------------------------------------------------
  var ws = null, retry = 500;

  function setConn(cls, text) {
    var el = document.getElementById("conn");
    el.className = "pill " + cls;
    document.getElementById("connText").textContent = text;
  }

  function connect() {
    var proto = location.protocol === "https:" ? "wss:" : "ws:";
    ws = new WebSocket(proto + "//" + location.host + "/ws");

    ws.onopen = function () { retry = 500; setConn("live", "connected"); };

    ws.onmessage = function (e) {
      var m;
      try { m = JSON.parse(e.data); } catch (err) { return; }
      handle(m);
    };

    ws.onclose = function () {
      setConn("down", "reconnecting");
      // The phone may have slept, or the clinician may have walked off the
      // Wi-Fi. Back off to 5 s and keep trying rather than needing a reload.
      setTimeout(connect, retry);
      retry = Math.min(retry * 2, 5000);
    };

    ws.onerror = function () { try { ws.close(); } catch (err) {} };
  }

  function handle(m) {
    switch (m.kind) {
      case "snapshot":   applySnapshot(m); break;
      case "features":   onFeatures(m); break;
      case "event":      log.unshift(m); log = log.slice(0, 200);
                         renderLog(); break;
      case "rep":        reps.push(m); renderReps(); renderTiles(); break;
      case "status":     status = m; renderDevice(); renderTiles(); break;
      case "config":     applyConfig(m); break;
      case "calibration": calib = m; renderDevice(); break;
      case "link":       if (m.state !== "ready") setConn("stale", m.label);
                         else setConn("live", "connected");
                         break;
      case "session":    if (m.started) { trace = []; reps = []; log = []; }
                         renderAll(); break;
      case "ping":       break;
      default: break;
    }
  }

  function applyConfig(c) {
    if (typeof c.target_angle_deg === "number") cfg.target = c.target_angle_deg;
    if (typeof c.peak_angle_deg === "number") cfg.peak = c.peak_angle_deg;
    if (typeof c.start_angle_deg === "number") cfg.start = c.start_angle_deg;
    if (typeof c.finish_angle_deg === "number") cfg.finish = c.finish_angle_deg;
    if (typeof c.rep_target === "number") cfg.repTarget = c.rep_target;
    if (typeof c.tempo_min_s === "number") cfg.tempoMin = c.tempo_min_s;
    if (typeof c.tempo_max_s === "number") cfg.tempoMax = c.tempo_max_s;
    renderAll();
  }

  function applySnapshot(s) {
    if (s.config) applyConfig(s.config);
    if (s.status) status = s.status;
    if (s.calibration) calib = s.calibration;
    if (s.device) {
      device = s.device;
      document.getElementById("devname").textContent =
        (device.name || "sleeve") + " · " + (device.id || "");
    }
    reps = s.reps || [];
    log = (s.log || []);
    trace = (s.trace || []).map(function (p) {
      return { t: p.t_us, angle: p.angle_deg, env: p.envelope,
               mdf: p.mdf, on: p.activation_on };
    });
    if (typeof s.rep_count === "number") lastRepCount = s.rep_count;
    meanScore = s.mean_score;
    mdfTrend = s.mdf_trend_hz;
    renderAll();
  }

  var lastRepCount = 0, meanScore = null, mdfTrend = null, lastFeature = null;

  function onFeatures(f) {
    lastFeature = f;
    lastFrameAt = Date.now();
    lastRepCount = f.rep_count;
    trace.push({ t: f.t_us, angle: f.angle_deg,
                 env: (f.envelope && f.envelope[0]) || 0,
                 mdf: (f.mdf && f.mdf[0]) || 0,
                 on: !!f.activation_on });
    if (trace.length > MAXPTS) trace.splice(0, trace.length - MAXPTS);
    renderTiles();
    draw();
  }

  // ---- tiles -----------------------------------------------------------
  function cls(v, lo, hi) {
    if (v == null) return "";
    if (v >= lo && v <= hi) return "good";
    var m = (hi - lo) * 0.25;
    return (v >= lo - m && v <= hi + m) ? "warn" : "bad";
  }

  function renderTiles() {
    var f = lastFeature;
    set("reps", lastRepCount);
    set("repsNote", "of " + cfg.repTarget);

    set("angle", f ? Math.round(f.angle_deg) + "°" : "—");
    set("angleNote", "peak " + Math.round(cfg.peak) + "°");
    var ang = document.getElementById("angle");
    ang.className = "v" + (f && f.angle_deg >= cfg.peak ? " good" : "");

    var env = f ? (f.envelope && f.envelope[0]) || 0 : null;
    set("effort", env == null ? "—" : Math.round(env * 100) + "%");
    document.getElementById("effort").className =
      "v" + (f && f.activation_on ? " warn" : "");
    set("effortNote", f && f.activation_on ? "muscle active" : "relaxed");

    set("score", meanScore == null ? "—" : Math.round(meanScore));
    document.getElementById("score").className =
      "v " + (meanScore == null ? "" : cls(meanScore, 70, 100));

    set("phase", f ? f.rep_state : "—");
    var comps = (f && f.compensations) || [];
    set("phaseNote", comps.length ? comps.join(", ") : " ");
    document.getElementById("phase").className =
      "v" + (comps.length ? " bad" : "");

    if (mdfTrend == null) { set("fatigue", "—"); }
    else {
      set("fatigue", (mdfTrend > 0 ? "+" : "") + mdfTrend.toFixed(1) + " Hz");
      document.getElementById("fatigue").className =
        "v" + (mdfTrend < -2 ? " warn" : "");
    }
  }

  function set(id, v) {
    var el = document.getElementById(id);
    if (el) el.textContent = String(v);
  }

  // ---- charts ----------------------------------------------------------
  function prep(canvas) {
    var dpr = window.devicePixelRatio || 1;
    var w = canvas.clientWidth, h = canvas.height;
    if (canvas.width !== Math.floor(w * dpr)) {
      canvas.width = Math.floor(w * dpr);
      canvas.style.height = h + "px";
      canvas.height = Math.floor(h * dpr);
    }
    var ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    return { ctx: ctx, w: w, h: h };
  }

  function draw() { drawAngle(); drawEmg(); }

  function drawAngle() {
    var c = document.getElementById("angleChart");
    var p = prep(c), ctx = p.ctx, w = p.w, h = p.h;
    var padL = 34, padR = 8, padT = 10, padB = 18;
    var iw = w - padL - padR, ih = h - padT - padB;

    var maxY = Math.max(cfg.target * 1.15, 120);
    function y(v) { return padT + ih - (v / maxY) * ih; }
    function x(i) {
      return padL + (trace.length < 2 ? 0 : (i / (MAXPTS - 1)) * iw);
    }

    // Rep band: start angle up to the peak criterion.
    ctx.fillStyle = "rgba(102,187,106,.10)";
    ctx.fillRect(padL, y(cfg.peak), iw, y(cfg.start) - y(cfg.peak));

    // Gridlines every 30 degrees.
    ctx.strokeStyle = "rgba(255,255,255,.055)";
    ctx.fillStyle = "#6b7681";
    ctx.font = "10px -apple-system, Segoe UI, Roboto, sans-serif";
    ctx.lineWidth = 1;
    for (var g = 0; g <= maxY; g += 30) {
      ctx.beginPath(); ctx.moveTo(padL, y(g)); ctx.lineTo(w - padR, y(g));
      ctx.stroke();
      ctx.fillText(g + "°", 4, y(g) + 3);
    }

    // The criterion, and the therapist target behind it.
    dashLine(ctx, padL, y(cfg.peak), w - padR, y(cfg.peak), "#66bb6a", 1.8);
    dashLine(ctx, padL, y(cfg.target), w - padR, y(cfg.target),
             "#6b7681", 1);

    if (trace.length > 1) {
      ctx.beginPath();
      for (var i = 0; i < trace.length; i++) {
        var px = x(i), py = y(trace[i].angle);
        if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
      }
      ctx.strokeStyle = "#4fc3f7";
      ctx.lineWidth = 2;
      ctx.lineJoin = "round";
      ctx.stroke();
    } else {
      ctx.fillStyle = "#6b7681";
      ctx.fillText("waiting for the stream", padL + 6, padT + 16);
    }
  }

  function drawEmg() {
    var c = document.getElementById("emgChart");
    var p = prep(c), ctx = p.ctx, w = p.w, h = p.h;
    var padL = 34, padR = 8, padT = 10, padB = 18;
    var iw = w - padL - padR, ih = h - padT - padB;

    function y(v) { return padT + ih - Math.min(v, 1.2) / 1.2 * ih; }
    function x(i) {
      return padL + (trace.length < 2 ? 0 : (i / (MAXPTS - 1)) * iw);
    }

    ctx.strokeStyle = "rgba(255,255,255,.055)";
    ctx.fillStyle = "#6b7681";
    ctx.font = "10px -apple-system, Segoe UI, Roboto, sans-serif";
    for (var g = 0; g <= 1.2; g += 0.25) {
      ctx.beginPath(); ctx.moveTo(padL, y(g)); ctx.lineTo(w - padR, y(g));
      ctx.stroke();
      ctx.fillText(Math.round(g * 100) + "%", 2, y(g) + 3);
    }

    // Shade the stretches the device calls active. Position carries the
    // meaning, not just the colour.
    ctx.fillStyle = "rgba(255,138,101,.20)";
    var runStart = -1;
    for (var i = 0; i < trace.length; i++) {
      if (trace[i].on && runStart < 0) runStart = i;
      if ((!trace[i].on || i === trace.length - 1) && runStart >= 0) {
        ctx.fillRect(x(runStart), padT, Math.max(x(i) - x(runStart), 1), ih);
        runStart = -1;
      }
    }

    if (trace.length > 1) {
      ctx.beginPath();
      for (var j = 0; j < trace.length; j++) {
        var px = x(j), py = y(trace[j].env);
        if (j === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
      }
      ctx.strokeStyle = "#ff8a65";
      ctx.lineWidth = 2;
      ctx.lineJoin = "round";
      ctx.stroke();
    }
  }

  function dashLine(ctx, x1, y1, x2, y2, color, lw) {
    ctx.save();
    ctx.setLineDash([5, 4]);
    ctx.strokeStyle = color;
    ctx.lineWidth = lw;
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    ctx.restore();
  }

  // ---- tables ----------------------------------------------------------
  function renderReps() {
    var wrap = document.getElementById("repTableWrap");
    if (!reps.length) {
      wrap.innerHTML = '<div class="empty">No repetitions yet.</div>';
      return;
    }
    var rows = reps.slice().reverse().map(function (r) {
      var pace = (r.duration_ms || 0) / 1000;
      var paceCls = cls(pace, cfg.tempoMin, cfg.tempoMax);
      var flagged = (r.compensations && r.compensations.length) ? "flagged" : "";
      return '<tr class="' + flagged + '">' +
        "<td>" + r.index + "</td>" +
        '<td class="score">' + r.score + "</td>" +
        "<td>" + Math.round((r.rom_fraction || 0) * 100) + "%</td>" +
        '<td class="' + paceCls + '">' + pace.toFixed(1) + " s</td>" +
        "<td>" + Math.round((r.smoothness || 0) * 100) + "%</td>" +
        "<td>" + Math.round(r.peak_angle_deg || 0) + "°</td>" +
        "<td>" + ((r.compensations || []).join(", ") || "—") + "</td>" +
        "</tr>";
    }).join("");

    wrap.innerHTML =
      "<table><thead><tr><th>#</th><th>Score</th><th>Range</th>" +
      "<th>Pace</th><th>Smooth</th><th>Peak</th><th>Flags</th>" +
      "</tr></thead><tbody>" + rows + "</tbody></table>";
  }

  function renderLog() {
    var el = document.getElementById("log");
    if (!log.length) {
      el.innerHTML = '<div class="empty">Nothing yet.</div>';
      return;
    }
    el.innerHTML = log.map(function (e) {
      var t = e.wall_clock ? new Date(e.wall_clock) : null;
      var hhmm = t ? t.toTimeString().slice(0, 8) : "";
      return '<div class="ev ' + (e.concerning ? "concerning" : "") + '">' +
        "<time>" + hhmm + "</time>" +
        '<div class="what">' + esc(e.label || "") +
        (e.detail ? ' <span class="detail">' + esc(e.detail) + "</span>" : "") +
        "</div></div>";
    }).join("");
  }

  function renderDevice() {
    var el = document.getElementById("devinfo");
    if (!status) { el.className = "empty";
                   el.textContent = "Waiting for status."; return; }
    el.className = "";
    var rows = [
      ["State", status.state],
      ["Fault", status.fault_code ? status.fault : "none"],
      ["Battery", status.battery_pct + "% (" + status.battery_mv + " mV)"],
      ["Signal quality", (status.signal_quality || []).join(", ")],
      ["Buffered range", status.seq_oldest + " … " + status.seq_newest],
      ["Data gap", status.gap_occurred ? "YES — unrecoverable" : "no"],
      ["PSRAM", status.psram_backed ? "backed" : "not backed"]
    ];
    if (calib) {
      rows.push(["Range of motion",
                 (calib.rom != null ? calib.rom.toFixed(1) + "°" : "—")]);
      if (calib.mvc_unreliable)
        rows.push(["Maximum", "measured value unreliable"]);
      if (calib.clinician_override)
        rows.push(["Maximum", "clinician-supplied"]);
    }
    el.innerHTML = "<table><tbody>" + rows.map(function (r) {
      return "<tr><td style='color:var(--ink-faint)'>" + esc(r[0]) +
             "</td><td>" + esc(String(r[1])) + "</td></tr>";
    }).join("") + "</tbody></table>";
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch];
    });
  }

  function renderAll() {
    renderTiles(); renderReps(); renderLog(); renderDevice(); draw();
  }

  // A stream that has stopped should say so rather than showing a frozen
  // trace that looks live.
  setInterval(function () {
    if (lastFrameAt && Date.now() - lastFrameAt > 3000 &&
        ws && ws.readyState === 1) {
      setConn("stale", "no frames");
    }
  }, 1000);

  window.addEventListener("resize", draw);
  renderAll();
  connect();
})();
</script>
</body>
</html>
''';
