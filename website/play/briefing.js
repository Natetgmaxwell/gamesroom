// Games Room — Briefing Generator (Tool A, mid-funnel lead magnet).
// Verbatim template matrix shared via /voices.js (V0.38 §6).
// Renders 3 briefings (on-create / 48h / morning-of) for one chosen voice
// in the 5×5 mascot matrix, with sentence-drop substitution so missing
// time / venue / seats cleanly drop the logistics sentence.

(function () {
  "use strict";

  var V = window.GamesRoomVoices;
  if (!V) {
    console.warn("[briefing] voices.js not loaded; aborting boot.");
    return;
  }
  var PERSONALITIES     = V.PERSONALITIES;
  var IDEOLOGIES        = V.IDEOLOGIES;
  var PERSONALITY_LABEL = V.PERSONALITY_LABEL;
  var IDEOLOGY_LABEL    = V.IDEOLOGY_LABEL;
  var IDEOLOGY_HEAD     = V.IDEOLOGY_HEAD;
  var VOICE_HINT        = V.VOICE_HINT;
  var MATRIX            = V.MATRIX;
  var interpolate       = V.interpolate;
  var dropEmptySentences = V.dropEmptySentences;

  // The 3 kinds, in order, with their tagged card labels.
  var KINDS = [
    { kind: "briefingOnCreate", tag: "Pre-event",     bodyId: "briefing-create-body",  labelId: "briefing-create-label" },
    { kind: "briefing48h",      tag: "Two days out",  bodyId: "briefing-48h-body",     labelId: "briefing-48h-label" },
    { kind: "briefingMorning",  tag: "Morning of",    bodyId: "briefing-morning-body", labelId: "briefing-morning-label" }
  ];

  // Selected voice pair (one of the 25 cells).
  var selectedPersonality = "snarky";
  var selectedIdeology    = "trickster";

  // ── 1. Render the 25-cell voice carousel ─────────────────────────────
  // The grid is a single horizontal strip; voice cards keep the chip
  // shape from Tool C so hosts recognise the picker. The host scrolls
  // / arrow-keys through, picks one, and the generate button reads the
  // selection. Default selected = "snarky · trickster".
  function renderCarousel() {
    var carousel = document.getElementById("voice-carousel");
    if (!carousel) return;
    var html = "";
    for (var p = 0; p < PERSONALITIES.length; p++) {
      var personality = PERSONALITIES[p];
      for (var i = 0; i < IDEOLOGIES.length; i++) {
        var ideology = IDEOLOGIES[i];
        var template = MATRIX.briefingOnCreate[personality][ideology];
        var preview = interpolate(template, {
          mascot: "Marlow",
          event: "Friday poker",
          time: "7:30pm",
          venue: ", my place",
          seats_left: "2"
        });
        // Sentence-drop to keep previews tidy when time/seats are empty.
        preview = dropEmptySentences(preview);
        var hint = VOICE_HINT[personality + "|" + ideology] || "";
        var isSelected = (personality === selectedPersonality && ideology === selectedIdeology);
        html +=
          '<button type="button" class="voice-carousel-card' + (isSelected ? " is-selected" : "") + '" ' +
          'data-personality="' + personality + '" data-ideology="' + ideology + '" ' +
          'aria-pressed="' + (isSelected ? "true" : "false") + '" ' +
          'aria-label="' + PERSONALITY_LABEL[personality] + " · " + IDEOLOGY_HEAD[ideology] +
          ' voice. Preview: ' + preview.replace(/"/g, "") + '">' +
          '<span class="voice-carousel-pair">' + PERSONALITY_LABEL[personality] +
          ' <span class="voice-carousel-dot">·</span> ' + IDEOLOGY_HEAD[ideology] + '</span>' +
          '<span class="voice-carousel-preview">' + escapeHtml(preview) + '</span>' +
          '<span class="voice-carousel-hint">' + escapeHtml(hint) + '</span>' +
          '</button>';
      }
    }
    carousel.innerHTML = html;
  }

  // ── 2. Voice selection ───────────────────────────────────────────────
  function pickVoice(personality, ideology) {
    selectedPersonality = personality;
    selectedIdeology    = ideology;
    var cards = document.querySelectorAll(".voice-carousel-card");
    for (var i = 0; i < cards.length; i++) {
      var c = cards[i];
      var matches =
        c.getAttribute("data-personality") === personality &&
        c.getAttribute("data-ideology")    === ideology;
      if (matches) {
        c.classList.add("is-selected");
        c.setAttribute("aria-pressed", "true");
        c.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "center" });
      } else {
        c.classList.remove("is-selected");
        c.setAttribute("aria-pressed", "false");
      }
    }
  }

  // ── 3. Parse "Friday 7:30pm, my place" into time + venue ─────────────
  // Time = first token followed by digits OR digit-led tokens. Venue = the
  // rest after the first comma. If no comma, everything after the first
  // space-separated chunk is venue. Falls back gracefully.
  function parseTimeAndVenue(raw) {
    var text = (raw || "").trim();
    if (!text) return { time: "", venue: "" };
    // Split at the FIRST comma → time = before, venue = after.
    var commaIdx = text.indexOf(",");
    var time, venue;
    if (commaIdx !== -1) {
      time  = text.slice(0, commaIdx).trim();
      venue = text.slice(commaIdx + 1).trim();
    } else {
      // No comma — try to detect a time chunk: first word that contains a digit.
      var parts = text.split(/\s+/);
      var timeIdx = -1;
      for (var i = 0; i < parts.length; i++) {
        if (/\d/.test(parts[i])) { timeIdx = i; break; }
      }
      if (timeIdx === -1) {
        // No time-like chunk → entire input is venue, time stays empty.
        time = "";
        venue = text;
      } else {
        // Time = first time-like chunk + any directly adjacent word ("7:30pm",
        // "Friday 7:30pm", "Friday at 7:30pm" handled by greedy group).
        var end = timeIdx + 1;
        // Include an "am/pm" or "o'clock" trailing word if present.
        if (end < parts.length && /^(am|pm|a\.m\.|p\.m\.|o'?clock)$/i.test(parts[end])) {
          end += 1;
        }
        time  = parts.slice(0, end).join(" ");
        venue = parts.slice(end).join(" ");
      }
    }
    if (venue) {
      // Prepend a comma so it slots in as "{time}{venue}" → "7:30pm, my place".
      venue = ", " + venue;
    }
    return { time: time, venue: venue };
  }

  // ── 4. Build vars from the form ──────────────────────────────────────
  function varsFromForm() {
    var form = document.getElementById("briefing-form-el");
    if (!form) return {};
    var mascot  = (document.getElementById("bf-mascot").value || "").trim();
    var room    = (document.getElementById("bf-room").value   || "").trim();
    var event   = (document.getElementById("bf-event").value  || "").trim();
    var tv      = (document.getElementById("bf-time-venue").value || "").trim();
    var seats   = (document.getElementById("bf-seats").value || "").trim();
    var parsed  = parseTimeAndVenue(tv);
    var vars = {
      mascot:        mascot,
      room:          room,
      event:         event,
      time:          parsed.time,
      venue:         parsed.venue,
      seats_left:    seats,
      seats_claimed: "" // not in form; sentence-drop keeps it out cleanly.
    };
    return vars;
  }

  // ── 5. Render the 3 briefing cards ──────────────────────────────────
  function renderOutput() {
    var vars = varsFromForm();
    for (var k = 0; k < KINDS.length; k++) {
      var cfg = KINDS[k];
      var template = MATRIX[cfg.kind][selectedPersonality][selectedIdeology];
      var body = interpolate(template, vars);
      body = dropEmptySentences(body);
      var bodyEl = document.getElementById(cfg.bodyId);
      if (bodyEl) bodyEl.textContent = body;
      var labelEl = document.getElementById(cfg.labelId);
      if (labelEl) labelEl.textContent = PERSONALITY_LABEL[selectedPersonality] +
        " · " + IDEOLOGY_HEAD[selectedIdeology] + " — " + cfg.tag;
    }
    // Echo the room name on every card.
    var roomText = vars.room || "";
    ["briefing-output-room-pre", "briefing-output-room-48", "briefing-output-room-morning"].forEach(function (id) {
      var el = document.getElementById(id);
      if (el) el.textContent = roomText;
    });
    var output = document.getElementById("briefing-output");
    if (output) {
      output.removeAttribute("hidden");
      output.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }

  // ── 6. Copy as text — all 3 briefings concatenated, iMessage-friendly ─
  function copyAsText() {
    var vars = varsFromForm();
    var voiceLabel = PERSONALITY_LABEL[selectedPersonality] + " · " + IDEOLOGY_HEAD[selectedIdeology];
    var room = vars.room || "";
    var lines = [];
    lines.push(voiceLabel + " — " + room);
    lines.push("");
    for (var k = 0; k < KINDS.length; k++) {
      var cfg = KINDS[k];
      var template = MATRIX[cfg.kind][selectedPersonality][selectedIdeology];
      var rendered = dropEmptySentences(interpolate(template, vars));
      lines.push("[" + cfg.tag + "]");
      lines.push(rendered);
      lines.push("");
    }
    var text = lines.join("\n").replace(/\n+$/, "");
    var status = document.getElementById("briefing-copy-status");
    var showStatus = function (msg) {
      if (!status) return;
      status.textContent = msg;
      setTimeout(function () { status.textContent = ""; }, 3500);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { showStatus("Copied. Paste into the group chat."); },
        function () { fallbackCopy(text); showStatus("Copied."); }
      );
    } else {
      fallbackCopy(text);
      showStatus("Copied.");
    }
  }

  function fallbackCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "absolute";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); } catch (_) {}
    document.body.removeChild(ta);
  }

  // ── 7. Download first card as PNG (IG-story sized 1080×1920) ─────────
  // The card visible on screen is small (~480px wide by design); we render
  // a sized-to-print clone at 1080×1920, capture, then download.
  function downloadAsPng() {
    if (!window.html2canvas) {
      var status = document.getElementById("briefing-copy-status");
      if (status) status.textContent = "Image library still loading — try again in a moment.";
      return;
    }
    var src = document.querySelector(".briefing-card[data-kind='briefingOnCreate']");
    if (!src) return;
    var filename = "games-room-briefing-" +
      (document.getElementById("bf-room").value || "room").trim().toLowerCase().replace(/\s+/g, "-").replace(/[^a-z0-9-]/g, "")
      + ".png";
    var status = document.getElementById("briefing-copy-status");
    if (status) status.textContent = "Rendering PNG…";

    // Build the IG-stories-sized clone off-screen, render, capture, download, remove.
    var clone = document.createElement("div");
    clone.style.position = "fixed";
    clone.style.left = "-99999px";
    clone.style.top = "0";
    clone.style.width = "1080px";
    clone.style.height = "1920px";
    clone.style.background = "#0A0A0B";
    clone.style.color = "#F4EFE6";
    clone.style.fontFamily = '"Fraunces", ui-serif, Georgia, "Times New Roman", serif';
    clone.style.padding = "120px 96px";
    clone.style.boxSizing = "border-box";
    clone.style.display = "flex";
    clone.style.flexDirection = "column";
    clone.style.justifyContent = "space-between";

    var tag = document.createElement("div");
    tag.style.fontSize = "40px";
    tag.style.letterSpacing = "0.12em";
    tag.style.textTransform = "uppercase";
    tag.style.color = "#B08D57";
    tag.style.fontFamily = '-apple-system, BlinkMacSystemFont, "SF Pro Rounded", system-ui, sans-serif';
    tag.textContent = "Pre-event · Games Room";

    var body = document.createElement("p");
    body.style.fontFamily = '"Fraunces", ui-serif, Georgia, "Times New Roman", serif';
    body.style.fontSize = "96px";
    body.style.lineHeight = "1.2";
    body.style.fontWeight = "400";
    body.style.margin = "0";
    body.style.color = "#F4EFE6";
    body.textContent = src.querySelector(".briefing-card-body").textContent;

    var room = document.createElement("div");
    room.style.fontSize = "44px";
    room.style.color = "rgba(244, 239, 230, 0.62)";
    room.style.fontFamily = '-apple-system, BlinkMacSystemFont, "SF Pro Rounded", system-ui, sans-serif';
    room.textContent = src.querySelector(".briefing-card-room").textContent || "";

    var mark = document.createElement("div");
    mark.style.fontSize = "36px";
    mark.style.letterSpacing = "0.08em";
    mark.style.textTransform = "uppercase";
    mark.style.color = "#B08D57";
    mark.style.fontFamily = '-apple-system, BlinkMacSystemFont, "SF Pro Rounded", system-ui, sans-serif';
    mark.textContent = "Games Room";

    clone.appendChild(tag);
    clone.appendChild(body);
    if (room.textContent) {
      clone.appendChild(room);
    }
    clone.appendChild(mark);
    document.body.appendChild(clone);

    window.html2canvas(clone, {
      backgroundColor: "#0A0A0B",
      width: 1080,
      height: 1920,
      scale: 1
    }).then(function (canvas) {
      document.body.removeChild(clone);
      var url = canvas.toDataURL("image/png");
      var a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      if (status) status.textContent = "PNG downloaded. Drop it in the chat.";
    }).catch(function () {
      if (clone.parentNode) document.body.removeChild(clone);
      if (status) status.textContent = "Couldn't render the PNG. Screenshot the card instead.";
    });
  }

  // ── 8. Email capture (mirrors mascot.js: mocked; real wire-up TODO) ──
  function submitEmail(email) {
    if (window.console && console.log) {
      console.log("[briefing] lead captured:", email);
    }
    return Promise.resolve({ ok: true, mocked: true });
  }

  // ── 9. Tiny HTML escape ─────────────────────────────────────────────
  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  // ── 10. Wire up ─────────────────────────────────────────────────────
  function wire() {
    // Carousel clicks
    var carousel = document.getElementById("voice-carousel");
    if (carousel) {
      carousel.addEventListener("click", function (ev) {
        var card = ev.target.closest && ev.target.closest(".voice-carousel-card");
        if (!card) return;
        var p = card.getAttribute("data-personality");
        var i = card.getAttribute("data-ideology");
        if (p && i) pickVoice(p, i);
      });
    }

    // Form submit → render output
    var form = document.getElementById("briefing-form-el");
    if (form) {
      form.addEventListener("submit", function (ev) {
        ev.preventDefault();
        var room  = (document.getElementById("bf-room").value || "").trim();
        var event = (document.getElementById("bf-event").value || "").trim();
        var mascot = (document.getElementById("bf-mascot").value || "").trim();
        if (!room || !event || !mascot) {
          // Bring focus to the first empty field.
          var targets = ["bf-room", "bf-event", "bf-mascot"];
          for (var i = 0; i < targets.length; i++) {
            var el = document.getElementById(targets[i]);
            if (el && !el.value.trim()) { el.focus(); break; }
          }
          return;
        }
        renderOutput();
      });
    }

    // Copy + download
    var copyBtn = document.getElementById("briefing-copy");
    if (copyBtn) copyBtn.addEventListener("click", copyAsText);
    var dlBtn = document.getElementById("briefing-download");
    if (dlBtn) dlBtn.addEventListener("click", downloadAsPng);

    // Email form
    var leadForm = document.getElementById("lead-form");
    if (leadForm) {
      var input = leadForm.querySelector('input[name="email"]');
      var status = document.getElementById("lead-status");
      var btn = leadForm.querySelector('button[type="submit"]');
      leadForm.addEventListener("submit", function (ev) {
        ev.preventDefault();
        if (!input || !input.value.trim()) {
          if (status) status.textContent = "Drop an email so we can reach you.";
          return;
        }
        submitEmail(input.value.trim()).then(function () {
          if (status) status.textContent = "You're on the list. We'll tell you when Games Room hits the App Store.";
          input.value = "";
          input.disabled = true;
          if (btn) btn.disabled = true;
        });
      });
    }

    // Arrow keys step the carousel.
    var carouselEl = document.getElementById("voice-carousel");
    if (carouselEl) {
      carouselEl.addEventListener("keydown", function (ev) {
        if (ev.key !== "ArrowLeft" && ev.key !== "ArrowRight") return;
        ev.preventDefault();
        var cards = carouselEl.querySelectorAll(".voice-carousel-card");
        var currentIdx = -1;
        for (var i = 0; i < cards.length; i++) {
          if (cards[i].classList.contains("is-selected")) { currentIdx = i; break; }
        }
        if (currentIdx === -1) currentIdx = 0;
        var dir = ev.key === "ArrowRight" ? 1 : -1;
        var nextIdx = (currentIdx + dir + cards.length) % cards.length;
        var nextCard = cards[nextIdx];
        if (nextCard) {
          var p = nextCard.getAttribute("data-personality");
          var i = nextCard.getAttribute("data-ideology");
          pickVoice(p, i);
          nextCard.focus();
        }
      });
    }
  }

  function boot() {
    renderCarousel();
    wire();
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
