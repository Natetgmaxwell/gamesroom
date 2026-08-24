// Games Room — Mascot Voice Sampler (Tool C, top-of-funnel lead magnet)
// Verbatim template matrix from docs/loop-artifacts/V0.38_MASCOT_VOICE_SPEC.md §6.
// Shared with /play/briefing via /voices.js — single source of truth.
// 5 personalities (rows) × 5 ideologies (columns) × 8 kinds = 200 cells.
// Page shows 4 kinds in the modal: .briefingOnCreate, .postPlayRecap, .inPlay, .standings.
// Placeholder contract (see voices.js):
//   {mascot}, {room} always-substituted.
//   {event}, {winner}, {leader}, {caller_rank}, {event_count}, {days_quiet},
//   {time}, {venue}, {seats_left}, {seats_claimed}, {member_count} —
//   all nil-preserving (empty string drops cleanly).

(function () {
  "use strict";

  // Shared module: window.GamesRoomVoices is loaded by /voices.js.
  var V = window.GamesRoomVoices;
  if (!V) {
    console.warn("[mascot-sampler] voices.js not loaded; aborting boot.");
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

  // ── Example placeholders ─────────────────────────────────────────────
  // The user can swap {room} live in the modal. Everything else is fixed.
  var EXAMPLE = {
    mascot: "Max",
    room: "the poker room",
    event: "Friday poker",
    leader: "Sam",
    winner: "Maeve",
    time: "7:30pm",
    venue: "my place",
    seats_left: "2",
    seats_claimed: "4",
    member_count: "6",
    days_quiet: "9",
    caller_rank: "3",
    event_count: "12"
  };

  // ── 6. Render: grid (25 cells, .briefingOnCreate preview) ────────────
  function renderGrid() {
    var grid = document.getElementById("voice-grid");
    if (!grid) return;
    var html = "";
    for (var p = 0; p < PERSONALITIES.length; p++) {
      var personality = PERSONALITIES[p];
      for (var i = 0; i < IDEOLOGIES.length; i++) {
        var ideology = IDEOLOGIES[i];
        var template = MATRIX.briefingOnCreate[personality][ideology];
        var caption = interpolate(template, EXAMPLE);
        var hint = VOICE_HINT[personality + "|" + ideology] || "";
        html +=
          '<button type="button" class="voice-cell" ' +
          'data-personality="' + personality + '" data-ideology="' + ideology + '" ' +
          'aria-label="' + PERSONALITY_LABEL[personality] + " · " + IDEOLOGY_HEAD[ideology] +
          ' voice preview">' +
          '<span class="voice-cell-pair">' + PERSONALITY_LABEL[personality] +
          ' <span class="voice-cell-dot">·</span> ' + IDEOLOGY_HEAD[ideology] + '</span>' +
          '<span class="voice-cell-caption">' + escapeHtml(caption) + '</span>' +
          '<span class="voice-cell-hint">' + escapeHtml(hint) + '</span>' +
          '</button>';
      }
    }
    grid.innerHTML = html;
  }

  // ── 7. Render: modal body (4 kinds for chosen personality × ideology) ─
  function renderModal(personality, ideology) {
    var body = document.getElementById("voice-modal-body");
    if (!body) return;
    var kinds = ["briefingOnCreate", "postPlayRecap", "inPlay", "standings"];
    var kindLabels = {
      briefingOnCreate: "Briefing (the room opens)",
      postPlayRecap: "Recap (after settle)",
      inPlay: "In play (the live footer)",
      standings: "Standings (between events)"
    };
    var vars = Object.assign({}, EXAMPLE);
    var roomInput = document.getElementById("room-name-input");
    if (roomInput && roomInput.value.trim()) {
      vars.room = roomInput.value.trim();
    }
    var html = "";
    for (var k = 0; k < kinds.length; k++) {
      var kind = kinds[k];
      var template = MATRIX[kind][personality][ideology];
      var caption = interpolate(template, vars);
      html +=
        '<li class="voice-kind">' +
        '<span class="voice-kind-label">' + kindLabels[kind] + '</span>' +
        '<p class="voice-kind-caption">' + escapeHtml(caption) + '</p>' +
        '</li>';
    }
    body.innerHTML = html;
  }

  // ── 8. Modal open / close ────────────────────────────────────────────
  var modalOpen = false;
  var currentPair = null; // { personality, ideology }

  function openModal(personality, ideology) {
    var modal = document.getElementById("voice-modal");
    var title = document.getElementById("voice-modal-title");
    var sub = document.getElementById("voice-modal-sub");
    if (!modal || !title || !sub) return;
    title.textContent = PERSONALITY_LABEL[personality] + " \u00b7 " + IDEOLOGY_HEAD[ideology];
    sub.textContent =
      "Personality: " + PERSONALITY_LABEL[personality] +
      " \u00b7 Politics: " + IDEOLOGY_HEAD[ideology] +
      " \u00b7 25 voices total";
    currentPair = { personality: personality, ideology: ideology };
    renderModal(personality, ideology);
    modal.removeAttribute("hidden");
    modal.setAttribute("aria-hidden", "false");
    modalOpen = true;
    document.body.classList.add("has-modal-open");
    // Move focus into the modal for keyboard users.
    var roomInput = document.getElementById("room-name-input");
    if (roomInput) setTimeout(function () { roomInput.focus(); }, 50);
  }

  function closeModal() {
    var modal = document.getElementById("voice-modal");
    if (!modal) return;
    modal.setAttribute("hidden", "");
    modal.setAttribute("aria-hidden", "true");
    modalOpen = false;
    currentPair = null;
    document.body.classList.remove("has-modal-open");
  }

  // ── 9. Email capture (mocked; surfaces a TODO per the brief) ─────────
  // Default per the brief: write to a simple `leads.json` on the page
  // (Cloudflare KV) and surface in the admin dashboard. Without a KV
  // binding wired, we mock the submit and surface a TODO so the form is
  // shippable as-is. When a real backend exists, the developer swaps
  // the fetch URL and removes the mock branch.
  function submitEmail(email) {
    // TODO(wire-backend): replace mock with POST to a real endpoint.
    // Default per brief §"Critical": write to a simple `leads.json` on
    // the page (Cloudflare KV) and surface in the admin dashboard.
    // For now, log to console so devs can verify the form wired up.
    if (window.console && console.log) {
      console.log("[mascot-sampler] lead captured:", email);
    }
    return Promise.resolve({ ok: true, mocked: true });
  }

  // ── 10. Wire up event handlers ───────────────────────────────────────
  function wire() {
    var grid = document.getElementById("voice-grid");
    if (grid) {
      grid.addEventListener("click", function (ev) {
        var cell = ev.target.closest && ev.target.closest(".voice-cell");
        if (!cell) return;
        var p = cell.getAttribute("data-personality");
        var i = cell.getAttribute("data-ideology");
        if (p && i) openModal(p, i);
      });
    }

    var modal = document.getElementById("voice-modal");
    if (modal) {
      var closeBtn = modal.querySelector("[data-close-modal]");
      if (closeBtn) closeBtn.addEventListener("click", closeModal);
      var backdrop = modal.querySelector(".voice-modal-backdrop");
      if (backdrop) backdrop.addEventListener("click", closeModal);
    }

    // Esc to close the modal.
    document.addEventListener("keydown", function (ev) {
      if (modalOpen && (ev.key === "Escape" || ev.keyCode === 27)) {
        closeModal();
      }
    });

    // Room-name input — re-render the modal captions live.
    var roomInput = document.getElementById("room-name-input");
    if (roomInput) {
      roomInput.addEventListener("input", function () {
        if (!modalOpen || !currentPair) return;
        renderModal(currentPair.personality, currentPair.ideology);
      });
    }

    // Email capture (two forms: modal + page-level).
    var forms = [
      { formId: "lead-form", statusId: "lead-status", inputId: "lead-email", submitLabel: "Save this voice" },
      { formId: "lead-form-modal", statusId: "lead-status-modal", inputId: "lead-email-modal", submitLabel: "Drop your email" }
    ];
    forms.forEach(function (cfg) {
      var form = document.getElementById(cfg.formId);
      if (!form) return;
      var input = form.querySelector('input[name="email"]');
      var status = document.getElementById(cfg.statusId);
      var btn = form.querySelector('button[type="submit"]');
      form.addEventListener("submit", function (ev) {
        ev.preventDefault();
        if (!input || !input.value.trim()) {
          if (status) status.textContent = "Drop an email so we can reach you.";
          return;
        }
        var captured = input.value.trim();
        submitEmail(captured).then(function () {
          if (status) {
            status.textContent = "You're on the list. We'll tell you when Games Room hits the App Store.";
          }
          input.value = "";
          input.disabled = true;
          if (btn) btn.disabled = true;
        });
      });
    });
  }

  // ── 11. Tiny HTML escape helper (defensive — templates contain punctuation) ──
  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  // ── 12. Boot ─────────────────────────────────────────────────────────
  function boot() {
    renderGrid();
    wire();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
