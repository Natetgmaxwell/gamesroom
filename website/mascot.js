// Games Room — Mascot Voice Sampler (Tool C, top-of-funnel lead magnet)
// Verbatim template matrix from docs/loop-artifacts/V0.38_MASCOT_VOICE_SPEC.md §6.
// 5 personalities (rows) × 5 ideologies (columns) × 8 kinds = 200 cells.
// Page shows 4 kinds in the modal: .briefingOnCreate, .postPlayRecap, .inPlay, .standings.
// Placeholder contract: {mascot}, {room} always-substituted.
//   {event}, {winner}, {leader}, {caller_rank}, {event_count}, {days_quiet},
//   {time}, {venue}, {seats_left}, {seats_claimed}, {member_count} —
//   all nil-preserving (empty string drops cleanly).

(function () {
  "use strict";

  // ── 1. Voice matrix (transcribed verbatim from V0.38 §6) ─────────────
  // Indexed as MATRIX[personality][ideology][kind].
  var PERSONALITIES = ["professional", "friendly", "snarky", "sarcastic", "unhinged"];
  var IDEOLOGIES = ["order", "centrist", "trickster", "anarchist", "apocalypse"];

  // Display labels (the same as the keys for now; kept as separate vars
  // so future renaming is one-line).
  var PERSONALITY_LABEL = {
    professional: "professional",
    friendly: "friendly",
    snarky: "snarky",
    sarcastic: "sarcastic",
    unhinged: "unhinged"
  };
  var IDEOLOGY_LABEL = {
    order: "order",
    centrist: "centrist",
    trickster: "trickster",
    anarchist: "anarchist",
    apocalypse: "apocalypse"
  };

  // Section heading (the rows of the grid) — slightly friendlier than
  // the lowercase ideology slugs above, used in the modal subhead.
  var IDEOLOGY_HEAD = {
    order: "Order",
    centrist: "Centrist",
    trickster: "Trickster",
    anarchist: "Anarchist",
    apocalypse: "Apocalypse"
  };

  // ── 2. Example placeholders ──────────────────────────────────────────
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

  // ── 3. Voice direction (per V0.38 §1) — used for cell chip labels ───
  // Shown under each cell as a 1-line voice hint so the grid reads as
  // a sampler, not a wall of identical captions.
  var VOICE_HINT = {
    // professional
    "professional|order": "declarative, no opinion",
    "professional|centrist": "neutral, table is set",
    "professional|trickster": "suspiciously orderly",
    "professional|anarchist": "informational claim",
    "professional|apocalypse": "the schedule holds",
    // friendly
    "friendly|order": "warm, host in hand",
    "friendly|centrist": "should be a good one",
    "friendly|trickster": "plotting the seating",
    "friendly|anarchist": "we show up because we want to",
    "friendly|apocalypse": "doomed together",
    // snarky
    "snarky|order": "binding, on time",
    "snarky|centrist": "read the room",
    "snarky|trickster": "don't all claim at once",
    "snarky|anarchist": "invitation, suggestion",
    "snarky|apocalypse": "known course, your call",
    // sarcastic
    "sarcastic|order": "air quotes on the host",
    "sarcastic|centrist": "plans are a suggestion",
    "sarcastic|trickster": "the chart may change",
    "sarcastic|anarchist": "we all know how that goes",
    "sarcastic|apocalypse": "the universe has ideas",
    // unhinged
    "unhinged|order": "I agree with the host",
    "unhinged|centrist": "I read the room three times",
    "unhinged|trickster": "already rearranged the chart",
    "unhinged|anarchist": "I disregard this authority",
    "unhinged|apocalypse": "fasten your discontent"
  };

  // ── 4. Template matrix (verbatim from V0.38 §6) ──────────────────────
  // All 200 cells. Transcribed exactly.
  var MATRIX = {
    briefingOnCreate: {
      professional: {
        order:     "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. The host will run it.",
        centrist:  "{mascot}: {event} is on the calendar. At {time}{venue}, {seats_left} left. The room will fill as it fills.",
        trickster: "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The seating chart I have in mind is suspiciously orderly.",
        anarchist: "{mascot}: {event} is recorded. At {time}{venue}, {seats_left} left. Attendance is voluntary; the host's claim to run it is informational.",
        apocalypse:"{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. The end remains on schedule."
      },
      friendly: {
        order:     "{mascot}: {event} is on the calendar! At {time}{venue}, {seats_left} left. The host has it all in hand.",
        centrist:  "{mascot}: {event} lands soon. At {time}{venue}, {seats_left} left. Should be a good one.",
        trickster: "{mascot}: {event} is booked. At {time}{venue}, {seats_left} left! The seating chart is already plotting.",
        anarchist: "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. We'll show up because we want to.",
        apocalypse:"{mascot}: {event} is on the calendar. At {time}{venue}, {seats_left} left. Doomed together, as usual."
      },
      snarky: {
        order:     "{mascot}: {event} is on the schedule. At {time}{venue}, {seats_left} left. On time, if you can manage it.",
        centrist:  "{mascot}: {event} is up. At {time}{venue}, {seats_left} left. Read the room before you commit.",
        trickster: "{mascot}: {event} is listed. At {time}{venue}, {seats_left} left. Don't all claim at once — save some for the chaos.",
        anarchist: "{mascot}: {event} is happening. At {time}{venue}, {seats_left} left. The host calls it an invitation; we call it a suggestion.",
        apocalypse:"{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left on a ship with a known course. Your call."
      },
      sarcastic: {
        order:     "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The host has it all 'under control.'",
        centrist:  "{mascot}: {event} is on. At {time}{venue}, {seats_left} left, give or take. Plans are a suggestion.",
        trickster: "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. I'm not saying the chart will change — but it might.",
        anarchist: "{mascot}: The host has 'scheduled' {event}. At {time}{venue}, {seats_left} left. We all know how that goes.",
        apocalypse:"{mascot}: {event} is on. At {time}{venue}, {seats_left} left. Sure, plan ahead — the universe has other ideas."
      },
      unhinged: {
        order:     "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The host has spoken, I agree with the host, and this is fine.",
        centrist:  "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. I read the room three times, and the room says yes.",
        trickster: "{mascot}: {event} is real. At {time}{venue}, {seats_left} left. I have already rearranged the seating chart, and everyone will notice.",
        anarchist: "{mascot}: The host scheduled {event}. At {time}{venue}, {seats_left} left. I disregard this authority and attend anyway.",
        apocalypse:"{mascot}: {event} is on. At {time}{venue}, {seats_left} left. Fasten your discontent for this ride."
      }
    },

    postPlayRecap: {
      professional: {
        order:     "{mascot}: {event} is concluded. The host ran it by the book. {winner} won the night.",
        centrist:  "{mascot}: {event} wrapped. The table holds at {member_count} strong. {winner} won the night.",
        trickster: "{mascot}: {event} is settled. The standings stand — provisionally. {winner} won the night.",
        anarchist: "{mascot}: {event} concluded. The ledger updated itself; no authority required. {winner} won the night.",
        apocalypse:"{mascot}: {event} is done. {winner} won the night. The end remains on schedule."
      },
      friendly: {
        order:     "{mascot}: What a night — {event} is in the books. The host ran a great table. Nice one, {winner}!",
        centrist:  "{mascot}: {event} is in the books. Good crowd, good table — {member_count} strong. Nice one, {winner}!",
        trickster: "{mascot}: {event} wrapped. Nice one, {winner}! I love everyone equally — the standings may have shifted, that's all.",
        anarchist: "{mascot}: {event} wrapped. Nobody was in charge and that's why it worked. Nice one, {winner}!",
        apocalypse:"{mascot}: {event} is over. We survived — barely. Nice one, {winner}."
      },
      snarky: {
        order:     "{mascot}: {event} is done. The host did their job. {winner} won — try to look surprised.",
        centrist:  "{mascot}: {event} wrapped. {member_count} strong, about what the room expected. {winner} won.",
        trickster: "{mascot}: {event} is over. Don't trust the standings — I may have re-sorted them. {winner} won.",
        anarchist: "{mascot}: {event} is done. The host called it a success — we call it a group decision. {winner} won.",
        apocalypse:"{mascot}: {event} is done. We are, somehow, still here — {winner} won, don't get used to it."
      },
      sarcastic: {
        order:     "{mascot}: {event} concluded 'according to plan.' Sure. {winner} won.",
        centrist:  "{mascot}: {event} wrapped. The room was exactly as predictable as yesterday. {winner} won.",
        trickster: "{mascot}: {event} is settled. The standings may have shifted since you last looked. {winner} won.",
        anarchist: "{mascot}: {event} is over. The host called it 'a successful event' — we call it 'people showed up.' {winner} won.",
        apocalypse:"{mascot}: {event} is done. We are not, somehow — {winner} won, don't expect it to last."
      },
      unhinged: {
        order:     "{mascot}: {event} is done. The host is satisfied, I am satisfied, and we are all satisfied — {winner} won, and we're all going to be fine.",
        centrist:  "{mascot}: {event} is in the past. The room is the same but different — {member_count} strong, and the number means something. {winner} won.",
        trickster: "{mascot}: {event} is over. The standings have been redrawn in invisible ink. {winner} won — you can't prove anything.",
        anarchist: "{mascot}: {event} is done. Nobody ran it, we all ran it, and {winner} won. The host is a figment.",
        apocalypse:"{mascot}: {event} is over. We're still here, which feels wrong — {winner} won, gloriously."
      }
    },

    inPlay: {
      professional: {
        order:     "{mascot}: {event} is underway. {leader} is in front. The host is running it.",
        centrist:  "{mascot}: {event} is live. {leader} leads. The room is in play.",
        trickster: "{mascot}: {event} is in progress. {leader} is in front — provisionally.",
        anarchist: "{mascot}: {event} is being played. {leader} leads. No authority required.",
        apocalypse:"{mascot}: {event} is underway. {leader} is in front. The end is still scheduled."
      },
      friendly: {
        order:     "{mascot}: {event} is live! {leader} is in front — great energy at the table. Someone's already at {event_count} nights.",
        centrist:  "{mascot}: {event} is underway. {leader} is leading — nice work tonight!",
        trickster: "{mascot}: {event} is happening! {leader} is in front — I've got my eye on the standings.",
        anarchist: "{mascot}: {event} is live! {leader} is in front — and everyone's here because they want to be.",
        apocalypse:"{mascot}: {event} is on. {leader} is in front. The world may be on fire, but the table is set."
      },
      snarky: {
        order:     "{mascot}: {event} is underway. {leader} is in front. The rest of you are playing for second.",
        centrist:  "{mascot}: {event} is live. {leader} leads. The room's most loyal regular is at {event_count} nights — not that anyone's counting.",
        trickster: "{mascot}: {event} is in play. {leader} is in front. Don't trust it — I may have re-sorted the board.",
        anarchist: "{mascot}: {event} is happening. {leader} is in front. The host calls it a race; we call it a suggestion.",
        apocalypse:"{mascot}: {event} is live. {leader} is in front of the ship's known course. Bring chips."
      },
      sarcastic: {
        order:     "{mascot}: {event} is underway. {leader} is in front, 'as expected.' Sure.",
        centrist:  "{mascot}: {event} is live. {leader} leads. I'm sure that'll hold.",
        trickster: "{mascot}: {event} is in progress. {leader} is in front — the standings may have shifted since you last looked.",
        anarchist: "{mascot}: {event} is happening. {leader} is 'winning.' The host says so.",
        apocalypse:"{mascot}: {event} is live. {leader} is in front of the wreckage. What could go wrong?"
      },
      unhinged: {
        order:     "{mascot}: {event} is underway. {leader} is in front, the host is in control, and I am in control — we are all fine.",
        centrist:  "{mascot}: {event} is live. {leader} is in front, the table is alive, and this is happening.",
        trickster: "{mascot}: {event} is happening. {leader} is in front, someone's at {event_count} nights, and the standings are in invisible ink — you can't prove anything.",
        anarchist: "{mascot}: {event} is live. {leader} is in front. Nobody is in charge, especially not the host.",
        apocalypse:"{mascot}: {event} is on. {leader} is in front, the fire is loud, the table is set, and we're all going."
      }
    },

    standings: {
      professional: {
        order:     "{mascot}: {room} stands between nights. {leader} holds the top of the table. You're #{caller_rank}.",
        centrist:  "{mascot}: {room} is between events. {leader} leads. Last night went to {winner}.",
        trickster: "{mascot}: {room} is between nights. {leader} is in front — provisionally. The most regular face is at {event_count} nights.",
        anarchist: "{mascot}: {room} has no event scheduled. {leader} leads the ungoverned table.",
        apocalypse:"{mascot}: {room} is between events. {leader} is in front. The end is still scheduled."
      },
      friendly: {
        order:     "{mascot}: {room} is between nights. {leader} is on top — and the most loyal regular's at {event_count} nights. Nice one, {winner}!",
        centrist:  "{mascot}: {room} is resting up. {leader} leads the pack. Last night went to {winner}.",
        trickster: "{mascot}: {room} is between events. {leader} is in front — for now, and I'm watching the standings. Someone's at {event_count} nights — exciting.",
        anarchist: "{mascot}: {room} is between nights. {leader} is in front, and everyone's here because they want to be. Nice one, {winner}!",
        apocalypse:"{mascot}: {room} is between events. {leader} is in front. We survived this far — same time next collapse?"
      },
      snarky: {
        order:     "{mascot}: {room} is between nights. {leader} is on top, you're #{caller_rank}, and the rest of you know where you stand.",
        centrist:  "{mascot}: {room} is quiet between events. {leader} leads — the most loyal regular's at {event_count} nights, and they know who they are.",
        trickster: "{mascot}: {room} is between nights. {leader} is in front. Don't trust it — I may have re-sorted the board.",
        anarchist: "{mascot}: {room} has no event on the books. {leader} is 'winning.' The host says so.",
        apocalypse:"{mascot}: {room} is between events. {leader} is in front of the ship's known course. Enjoy the calm."
      },
      sarcastic: {
        order:     "{mascot}: {room} is between nights. {leader} is in front, 'as expected.' Sure — you're #{caller_rank}.",
        centrist:  "{mascot}: {room} is between events. {leader} leads. I'm sure that'll hold.",
        trickster: "{mascot}: {room} is between nights. {leader} is in front — the standings may have shifted since you last looked. Someone's at {event_count} nights, not that anyone's counting.",
        anarchist: "{mascot}: The host has 'scheduled' nothing for {room}. {leader} is 'winning' anyway.",
        apocalypse:"{mascot}: {room} is between events. {leader} is in front of the wreckage. What could go wrong?"
      },
      unhinged: {
        order:     "{mascot}: {room} is between nights. {leader} is on top, you're #{caller_rank}, and the host will schedule the next one — I am calm.",
        centrist:  "{mascot}: {room} is between events. {leader} is in front, the table hums with possibility, and someone's at {event_count} nights now.",
        trickster: "{mascot}: {room} is between nights. {leader} is in front, the standings have been redrawn in invisible ink, and you can't prove anything.",
        anarchist: "{mascot}: {room} has no event. {leader} is in front, nobody is in charge, and the table waits for no one.",
        apocalypse:"{mascot}: {room} is between events. {leader} is in front, the fire is loud, the table is set, and we're all going."
      }
    }
  };

  // ── 5. Interpolator (nil-preserving for ALL known placeholders) ──────
  // Mirrors GamesRoom/Services/MascotEngine.swift `interpolate()` —
  // unknown / empty placeholders drop cleanly. We render ALL placeholders
  // with example values (not nil) because the page is a sampler; the
  // sentence-drop pass from the Swift engine is bypassed intentionally.
  function interpolate(template, vars) {
    return template.replace(/\{(\w+)\}/g, function (_, key) {
      var v = vars[key];
      if (v === undefined || v === null || v === "") return "";
      return String(v);
    });
  }

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
