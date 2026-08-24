// Games Room — shared voice matrix module.
// Transcribed verbatim from docs/loop-artifacts/V0.38_MASCOT_VOICE_SPEC.md §6.
// 5 personalities (rows) × 5 ideologies (columns) × 8 kinds = 200 cells.
// Both /play/mascot and /play/briefing import this module — single source.
//
// Placeholder contract (mirrors GamesRoom/Services/MascotEngine.swift):
//   {mascot}, {room}            — always-substituted.
//   {event}, {winner}, {leader}, {caller_rank}, {event_count},
//   {days_quiet}, {time}, {venue}, {seats_left}, {seats_claimed},
//   {member_count}              — nil-preserving. Empty string drops cleanly.
//   {date}, {host_note}         — kept "": no template uses them.
//
// `dropEmptySentences` (the page-side sentence-drop): removes any
// sentence (split on `. `) that still contains a `{` placeholder. This
// mirrors the Swift engine's `interpolate()` user-facing output.

(function (root) {
  "use strict";

  // ── 1. Axes ───────────────────────────────────────────────────────────
  var PERSONALITIES = ["professional", "friendly", "snarky", "sarcastic", "unhinged"];
  var IDEOLOGIES    = ["order", "centrist", "trickster", "anarchist", "apocalypse"];

  var PERSONALITY_LABEL = {
    professional: "professional",
    friendly:     "friendly",
    snarky:       "snarky",
    sarcastic:    "sarcastic",
    unhinged:     "unhinged"
  };
  var IDEOLOGY_LABEL = {
    order:      "order",
    centrist:   "centrist",
    trickster:  "trickster",
    anarchist:   "anarchist",
    apocalypse: "apocalypse"
  };
  var IDEOLOGY_HEAD = {
    order:      "Order",
    centrist:   "Centrist",
    trickster:  "Trickster",
    anarchist:   "Anarchist",
    apocalypse: "Apocalypse"
  };

  // ── 2. Voice direction one-liners (per V0.38 §1) ──────────────────────
  // 1-line voice hint used in the voice grid / carousel so the 25 cells
  // read as a sampler, not a wall of identical captions.
  var VOICE_HINT = {
    "professional|order":      "declarative, no opinion",
    "professional|centrist":   "neutral, table is set",
    "professional|trickster":  "suspiciously orderly",
    "professional|anarchist":  "informational claim",
    "professional|apocalypse": "the schedule holds",
    "friendly|order":          "warm, host in hand",
    "friendly|centrist":       "should be a good one",
    "friendly|trickster":      "plotting the seating",
    "friendly|anarchist":      "we show up because we want to",
    "friendly|apocalypse":     "doomed together",
    "snarky|order":            "binding, on time",
    "snarky|centrist":         "read the room",
    "snarky|trickster":        "don't all claim at once",
    "snarky|anarchist":        "invitation, suggestion",
    "snarky|apocalypse":       "known course, your call",
    "sarcastic|order":         "air quotes on the host",
    "sarcastic|centrist":      "plans are a suggestion",
    "sarcastic|trickster":     "the chart may change",
    "sarcastic|anarchist":     "we all know how that goes",
    "sarcastic|apocalypse":    "the universe has ideas",
    "unhinged|order":          "I agree with the host",
    "unhinged|centrist":       "I read the room three times",
    "unhinged|trickster":      "already rearranged the chart",
    "unhinged|anarchist":      "I disregard this authority",
    "unhinged|apocalypse":     "fasten your discontent"
  };

  // ── 3. Template matrix — ALL 200 cells, verbatim ──────────────────────

  var MATRIX = {

    briefingOnCreate: {
      professional: {
        order:      "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. The host will run it.",
        centrist:   "{mascot}: {event} is on the calendar. At {time}{venue}, {seats_left} left. The room will fill as it fills.",
        trickster:  "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The seating chart I have in mind is suspiciously orderly.",
        anarchist:  "{mascot}: {event} is recorded. At {time}{venue}, {seats_left} left. Attendance is voluntary; the host's claim to run it is informational.",
        apocalypse: "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. The end remains on schedule."
      },
      friendly: {
        order:      "{mascot}: {event} is on the calendar! At {time}{venue}, {seats_left} left. The host has it all in hand.",
        centrist:   "{mascot}: {event} lands soon. At {time}{venue}, {seats_left} left. Should be a good one.",
        trickster:  "{mascot}: {event} is booked. At {time}{venue}, {seats_left} left! The seating chart is already plotting.",
        anarchist:  "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. We'll show up because we want to.",
        apocalypse: "{mascot}: {event} is on the calendar. At {time}{venue}, {seats_left} left. Doomed together, as usual."
      },
      snarky: {
        order:      "{mascot}: {event} is on the schedule. At {time}{venue}, {seats_left} left. On time, if you can manage it.",
        centrist:   "{mascot}: {event} is up. At {time}{venue}, {seats_left} left. Read the room before you commit.",
        trickster:  "{mascot}: {event} is listed. At {time}{venue}, {seats_left} left. Don't all claim at once — save some for the chaos.",
        anarchist:  "{mascot}: {event} is happening. At {time}{venue}, {seats_left} left. The host calls it an invitation; we call it a suggestion.",
        apocalypse: "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left on a ship with a known course. Your call."
      },
      sarcastic: {
        order:      "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The host has it all 'under control.'",
        centrist:   "{mascot}: {event} is on. At {time}{venue}, {seats_left} left, give or take. Plans are a suggestion.",
        trickster:  "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. I'm not saying the chart will change — but it might.",
        anarchist:  "{mascot}: The host has 'scheduled' {event}. At {time}{venue}, {seats_left} left. We all know how that goes.",
        apocalypse: "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. Sure, plan ahead — the universe has other ideas."
      },
      unhinged: {
        order:      "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The host has spoken, I agree with the host, and this is fine.",
        centrist:   "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. I read the room three times, and the room says yes.",
        trickster:  "{mascot}: {event} is real. At {time}{venue}, {seats_left} left. I have already rearranged the seating chart, and everyone will notice.",
        anarchist:  "{mascot}: The host scheduled {event}. At {time}{venue}, {seats_left} left. I disregard this authority and attend anyway.",
        apocalypse: "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. Fasten your discontent for this ride."
      }
    },

    briefing48h: {
      professional: {
        order:      "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The schedule holds.",
        centrist:   "{mascot}: {event} is two days out. At {time}{venue}, {seats_claimed} in so far.",
        trickster:  "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The seating chart is provisional.",
        anarchist:  "{mascot}: {event} is two days out. At {time}{venue}, {seats_claimed} in. Participation remains ungoverned.",
        apocalypse: "{mascot}: Two days to {event}. At {time}{venue}, {seats_claimed} in. The inevitable has accepted company."
      },
      friendly: {
        order:      "{mascot}: Two days until {event}! At {time}{venue}, {seats_claimed} in. The host has it in hand.",
        centrist:   "{mascot}: {event} is two days out. At {time}{venue}, {seats_claimed} in — still room for more.",
        trickster:  "{mascot}: Two days to {event}. At {time}{venue}, {seats_claimed} in! The standings are already looking rearrangeable.",
        anarchist:  "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. Come if you want.",
        apocalypse: "{mascot}: Two days to {event}. At {time}{venue}, {seats_claimed} in. The end of the world waits for no one."
      },
      snarky: {
        order:      "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The briefing is binding.",
        centrist:   "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. Choose wisely.",
        trickster:  "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in — a suggestion, not a rule.",
        anarchist:  "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The host will pretend to be in charge — let them.",
        apocalypse: "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The wreckage has a waitlist."
      },
      sarcastic: {
        order:      "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. I'm sure we'll all follow procedure.",
        centrist:   "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in, give or take.",
        trickster:  "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in — adorably committed.",
        anarchist:  "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The host will 'organize' it.",
        apocalypse: "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. Sure, plan ahead."
      },
      unhinged: {
        order:      "{mascot}: Two days to {event}. At {time}{venue}, {seats_claimed} in. The host's calendar is law, I will comply, and so will you.",
        centrist:   "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. I checked the room twice — it's still there.",
        trickster:  "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. I have already moved them twice, and they haven't noticed.",
        anarchist:  "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The host's calendar is a very specific suggestion.",
        apocalypse: "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The lamp knows the plan."
      }
    },

    briefingMorning: {
      professional: {
        order:      "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host will be ready.",
        centrist:   "{mascot}: {event} runs today. At {time}{venue}, {seats_left} still open. The table is set.",
        trickster:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The seating chart has been amended twice.",
        anarchist:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host's claim to run it is informational.",
        apocalypse: "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The collapse window is open."
      },
      friendly: {
        order:      "{mascot}: It's {event} day! At {time}{venue}, {seats_left} still open. The host is ready — so are we.",
        centrist:   "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Anyone else in?",
        trickster:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Who's last-minute swapping seats — don't be shy.",
        anarchist:  "{mascot}: {event} is on today. At {time}{venue}, {seats_left} still open. The host thinks they scheduled it, but we know better.",
        apocalypse: "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The world may be on fire, but the table is set."
      },
      snarky: {
        order:      "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Show up on time — the host will notice.",
        centrist:   "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Last call before the room fills.",
        trickster:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. I shuffled the seating chart in my head — you're welcome.",
        anarchist:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host's authority to declare this is fine — whatever, see you there.",
        apocalypse: "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The bridge is on fire — bring chips."
      },
      sarcastic: {
        order:      "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host is 'prepared' — we'll improvise.",
        centrist:   "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Last call — though we both know walk-ins will happen.",
        trickster:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. I rearranged the standings in my head last night — you're welcome.",
        anarchist:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Yes, the host is in charge — no, that's not how this works.",
        apocalypse: "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The room is on fire — we're doing this anyway."
      },
      unhinged: {
        order:      "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host is awake, I am awake, and everyone is awake — it's happening.",
        centrist:   "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. I checked the room three times — it's ready, mostly.",
        trickster:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. I reshuffled the seat grid at 3 AM — don't check your inbox.",
        anarchist:  "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Nobody is in charge — especially not me, definitely not the host.",
        apocalypse: "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The fire is loud, the table is set, and we're all going."
      }
    },

    postPlayRecap: {
      professional: {
        order:      "{mascot}: {event} is concluded. The host ran it by the book. {winner} won the night.",
        centrist:   "{mascot}: {event} wrapped. The table holds at {member_count} strong. {winner} won the night.",
        trickster:  "{mascot}: {event} is settled. The standings stand — provisionally. {winner} won the night.",
        anarchist:  "{mascot}: {event} concluded. The ledger updated itself; no authority required. {winner} won the night.",
        apocalypse: "{mascot}: {event} is done. {winner} won the night. The end remains on schedule."
      },
      friendly: {
        order:      "{mascot}: What a night — {event} is in the books. The host ran a great table. Nice one, {winner}!",
        centrist:   "{mascot}: {event} is in the books. Good crowd, good table — {member_count} strong. Nice one, {winner}!",
        trickster:  "{mascot}: {event} wrapped. Nice one, {winner}! I love everyone equally — the standings may have shifted, that's all.",
        anarchist:  "{mascot}: {event} wrapped. Nobody was in charge and that's why it worked. Nice one, {winner}!",
        apocalypse: "{mascot}: {event} is over. We survived — barely. Nice one, {winner}."
      },
      snarky: {
        order:      "{mascot}: {event} is done. The host did their job. {winner} won — try to look surprised.",
        centrist:   "{mascot}: {event} wrapped. {member_count} strong, about what the room expected. {winner} won.",
        trickster:  "{mascot}: {event} is over. Don't trust the standings — I may have re-sorted them. {winner} won.",
        anarchist:  "{mascot}: {event} is done. The host called it a success — we call it a group decision. {winner} won.",
        apocalypse: "{mascot}: {event} is done. We are, somehow, still here — {winner} won, don't get used to it."
      },
      sarcastic: {
        order:      "{mascot}: {event} concluded 'according to plan.' Sure. {winner} won.",
        centrist:   "{mascot}: {event} wrapped. The room was exactly as predictable as yesterday. {winner} won.",
        trickster:  "{mascot}: {event} is settled. The standings may have shifted since you last looked. {winner} won.",
        anarchist:  "{mascot}: {event} is over. The host called it 'a successful event' — we call it 'people showed up.' {winner} won.",
        apocalypse: "{mascot}: {event} is done. We are not, somehow — {winner} won, don't expect it to last."
      },
      unhinged: {
        order:      "{mascot}: {event} is done. The host is satisfied, I am satisfied, and we are all satisfied — {winner} won, and we're all going to be fine.",
        centrist:   "{mascot}: {event} is in the past. The room is the same but different — {member_count} strong, and the number means something. {winner} won.",
        trickster:  "{mascot}: {event} is over. The standings have been redrawn in invisible ink. {winner} won — you can't prove anything.",
        anarchist:  "{mascot}: {event} is done. Nobody ran it, we all ran it, and {winner} won. The host is a figment.",
        apocalypse: "{mascot}: {event} is over. We're still here, which feels wrong — {winner} won, gloriously."
      }
    },

    inPlay: {
      professional: {
        order:      "{mascot}: {event} is underway. {leader} is in front. The host is running it.",
        centrist:   "{mascot}: {event} is live. {leader} leads. The room is in play.",
        trickster:  "{mascot}: {event} is in progress. {leader} is in front — provisionally.",
        anarchist:  "{mascot}: {event} is being played. {leader} leads. No authority required.",
        apocalypse: "{mascot}: {event} is underway. {leader} is in front. The end is still scheduled."
      },
      friendly: {
        order:      "{mascot}: {event} is live! {leader} is in front — great energy at the table. Someone's already at {event_count} nights.",
        centrist:   "{mascot}: {event} is underway. {leader} is leading — nice work tonight!",
        trickster:  "{mascot}: {event} is happening! {leader} is in front — I've got my eye on the standings.",
        anarchist:  "{mascot}: {event} is live! {leader} is in front — and everyone's here because they want to be.",
        apocalypse: "{mascot}: {event} is on. {leader} is in front. The world may be on fire, but the table is set."
      },
      snarky: {
        order:      "{mascot}: {event} is underway. {leader} is in front. The rest of you are playing for second.",
        centrist:   "{mascot}: {event} is live. {leader} leads. The room's most loyal regular is at {event_count} nights — not that anyone's counting.",
        trickster:  "{mascot}: {event} is in play. {leader} is in front. Don't trust it — I may have re-sorted the board.",
        anarchist:  "{mascot}: {event} is happening. {leader} is in front. The host calls it a race; we call it a suggestion.",
        apocalypse: "{mascot}: {event} is live. {leader} is in front of the ship's known course. Bring chips."
      },
      sarcastic: {
        order:      "{mascot}: {event} is underway. {leader} is in front, 'as expected.' Sure.",
        centrist:   "{mascot}: {event} is live. {leader} leads. I'm sure that'll hold.",
        trickster:  "{mascot}: {event} is in progress. {leader} is in front — the standings may have shifted since you last looked.",
        anarchist:  "{mascot}: {event} is happening. {leader} is 'winning.' The host says so.",
        apocalypse: "{mascot}: {event} is live. {leader} is in front of the wreckage. What could go wrong?"
      },
      unhinged: {
        order:      "{mascot}: {event} is underway. {leader} is in front, the host is in control, and I am in control — we are all fine.",
        centrist:   "{mascot}: {event} is live. {leader} is in front, the table is alive, and this is happening.",
        trickster:  "{mascot}: {event} is happening. {leader} is in front, someone's at {event_count} nights, and the standings are in invisible ink — you can't prove anything.",
        anarchist:  "{mascot}: {event} is live. {leader} is in front. Nobody is in charge, especially not the host.",
        apocalypse: "{mascot}: {event} is on. {leader} is in front, the fire is loud, the table is set, and we're all going."
      }
    },

    roomWelcome: {
      professional: {
        order:      "{mascot}: Welcome to {room}. No events yet — the host will announce the first night.",
        centrist:   "{mascot}: {room} is open. No events on the books yet. The table is waiting.",
        trickster:  "{mascot}: {room} exists. No events yet, which is suspiciously quiet. The host is up to something.",
        anarchist:  "{mascot}: {room} has no events scheduled. The table is ungoverned and ready.",
        apocalypse: "{mascot}: {room} stands empty of events. The end is not yet scheduled."
      },
      friendly: {
        order:      "{mascot}: Welcome to {room}! No events yet — the host is cooking up the first night.",
        centrist:   "{mascot}: Welcome to {room}! First event coming soon — don't miss it.",
        trickster:  "{mascot}: {room} is open! No events yet, but I can feel the chaos warming up.",
        anarchist:  "{mascot}: Welcome to {room}! Nothing scheduled yet — we'll show up when we want to.",
        apocalypse: "{mascot}: {room} is here. No events yet. Not doomed tonight."
      },
      snarky: {
        order:      "{mascot}: {room} is open. No events scheduled — the host will get to it, eventually.",
        centrist:   "{mascot}: {room} has no events yet. The table is waiting. Read the room before you commit.",
        trickster:  "{mascot}: {room}, no events yet. I've already planned the seating chart for a night that doesn't exist.",
        anarchist:  "{mascot}: {room} is event-free. The host says 'soon.' I say 'we'll see.'",
        apocalypse: "{mascot}: {room} has no events. The ship is docked. Enjoy it while it lasts."
      },
      sarcastic: {
        order:      "{mascot}: Oh good, {room} is open. No events yet. The host is 'working on it,' I'm sure.",
        centrist:   "{mascot}: {room} is live with zero events. A fresh start. How optimistic of us.",
        trickster:  "{mascot}: {room} has no events yet. I'm sure the schedule will hold. It never holds.",
        anarchist:  "{mascot}: The host has 'planned' nothing for {room}. A bold strategy.",
        apocalypse: "{mascot}: {room} is open, event-free. The calm before the collapse. Enjoy it."
      },
      unhinged: {
        order:      "{mascot}: {room} is open. No events yet — the host will announce the first night, and I am calm. This is fine.",
        centrist:   "{mascot}: {room} is here. No events — the table hums with possibility, I checked.",
        trickster:  "{mascot}: {room} has no events. I have already rearranged the seating chart for a night that doesn't exist. You're welcome.",
        anarchist:  "{mascot}: {room} is event-free. Nobody is in charge. The table is ready for anything, especially nothing.",
        apocalypse: "{mascot}: {room} stands empty. The first night is coming. Fasten your discontent."
      }
    },

    roomStale: {
      professional: {
        order:      "{mascot}: No sessions in {room} for {days_quiet} days. The host will schedule the next night.",
        centrist:   "{mascot}: {room} has been quiet for {days_quiet} days. The table is waiting.",
        trickster:  "{mascot}: {room} has been silent for {days_quiet} days. Suspiciously silent. The standings are up to something.",
        anarchist:  "{mascot}: {room} has seen no play in {days_quiet} days. The table remains ungoverned.",
        apocalypse: "{mascot}: {room} has been quiet for {days_quiet} days. The end is patient."
      },
      friendly: {
        order:      "{mascot}: It's been {days_quiet} days since {room} last played. The host misses you — come back soon!",
        centrist:   "{mascot}: {room} has been quiet for {days_quiet} days. The table's still set — first one to claim a seat wins the night.",
        trickster:  "{mascot}: {room} has been quiet for {days_quiet} days. Too quiet. I've been rearranging the standings to pass the time.",
        anarchist:  "{mascot}: {room} hasn't played in {days_quiet} days. No pressure — we'll gather when we want to.",
        apocalypse: "{mascot}: {room} has been quiet for {days_quiet} days. We survived the silence. Same time next collapse?"
      },
      snarky: {
        order:      "{mascot}: {room} has been quiet for {days_quiet} days. The host is 'between nights.' Sure.",
        centrist:   "{mascot}: {room} has been quiet for {days_quiet} days. The table is getting dusty.",
        trickster:  "{mascot}: {room} has been silent for {days_quiet} days. I've re-sorted the standings twice. You're welcome.",
        anarchist:  "{mascot}: {room} hasn't played in {days_quiet} days. The host says 'soon.' I've heard that before.",
        apocalypse: "{mascot}: {room} has been quiet for {days_quiet} days. The ship is still sinking. Slowly."
      },
      sarcastic: {
        order:      "{mascot}: {room} has been quiet for {days_quiet} days. The host is 'planning something special,' I'm sure.",
        centrist:   "{mascot}: {room} has been quiet for {days_quiet} days. How peaceful. How suspicious.",
        trickster:  "{mascot}: {room} has been silent for {days_quiet} days. The standings may have shifted. Just a hunch.",
        anarchist:  "{mascot}: The host has 'scheduled' nothing for {room} in {days_quiet} days. A bold strategy.",
        apocalypse: "{mascot}: {room} has been quiet for {days_quiet} days. The calm before the collapse. Enjoy it."
      },
      unhinged: {
        order:      "{mascot}: {room} has been quiet for {days_quiet} days. The host will schedule the next night, and I am patient — this is fine.",
        centrist:   "{mascot}: {room} — {days_quiet} days of silence, and the table hums with anticipation. Come back!",
        trickster:  "{mascot}: {room} has been quiet for {days_quiet} days. I have rearranged the standings in my head — nobody will notice, but everyone will.",
        anarchist:  "{mascot}: {room} hasn't played in {days_quiet} days. Nobody is in charge. The table waits for no one.",
        apocalypse: "{mascot}: {room} has been quiet for {days_quiet} days. The end is still coming. Fasten your discontent."
      }
    },

    standings: {
      professional: {
        order:      "{mascot}: {room} stands between nights. {leader} holds the top of the table. You're #{caller_rank}.",
        centrist:   "{mascot}: {room} is between events. {leader} leads. Last night went to {winner}.",
        trickster:  "{mascot}: {room} is between nights. {leader} is in front — provisionally. The most regular face is at {event_count} nights.",
        anarchist:  "{mascot}: {room} has no event scheduled. {leader} leads the ungoverned table.",
        apocalypse: "{mascot}: {room} is between events. {leader} is in front. The end is still scheduled."
      },
      friendly: {
        order:      "{mascot}: {room} is between nights. {leader} is on top — and the most loyal regular's at {event_count} nights. Nice one, {winner}!",
        centrist:   "{mascot}: {room} is resting up. {leader} leads the pack. Last night went to {winner}.",
        trickster:  "{mascot}: {room} is between events. {leader} is in front — for now, and I'm watching the standings. Someone's at {event_count} nights — exciting.",
        anarchist:  "{mascot}: {room} is between nights. {leader} is in front, and everyone's here because they want to be. Nice one, {winner}!",
        apocalypse: "{mascot}: {room} is between events. {leader} is in front. We survived this far — same time next collapse?"
      },
      snarky: {
        order:      "{mascot}: {room} is between nights. {leader} is on top, you're #{caller_rank}, and the rest of you know where you stand.",
        centrist:   "{mascot}: {room} is quiet between events. {leader} leads — the most loyal regular's at {event_count} nights, and they know who they are.",
        trickster:  "{mascot}: {room} is between nights. {leader} is in front. Don't trust it — I may have re-sorted the board.",
        anarchist:  "{mascot}: {room} has no event on the books. {leader} is 'winning.' The host says so.",
        apocalypse: "{mascot}: {room} is between events. {leader} is in front of the ship's known course. Enjoy the calm."
      },
      sarcastic: {
        order:      "{mascot}: {room} is between nights. {leader} is in front, 'as expected.' Sure — you're #{caller_rank}.",
        centrist:   "{mascot}: {room} is between events. {leader} leads. I'm sure that'll hold.",
        trickster:  "{mascot}: {room} is between nights. {leader} is in front — the standings may have shifted since you last looked. Someone's at {event_count} nights, not that anyone's counting.",
        anarchist:  "{mascot}: The host has 'scheduled' nothing for {room}. {leader} is 'winning' anyway.",
        apocalypse: "{mascot}: {room} is between events. {leader} is in front of the wreckage. What could go wrong?"
      },
      unhinged: {
        order:      "{mascot}: {room} is between nights. {leader} is on top, you're #{caller_rank}, and the host will schedule the next one — I am calm.",
        centrist:   "{mascot}: {room} is between events. {leader} is in front, the table hums with possibility, and someone's at {event_count} nights now.",
        trickster:  "{mascot}: {room} is between nights. {leader} is in front, the standings have been redrawn in invisible ink, and you can't prove anything.",
        anarchist:  "{mascot}: {room} has no event. {leader} is in front, nobody is in charge, and the table waits for no one.",
        apocalypse: "{mascot}: {room} is between events. {leader} is in front, the fire is loud, the table is set, and we're all going."
      }
    }
  };

  // ── 4. Interpolator (nil-preserving for ALL known placeholders) ──────
  // Empty / undefined / null placeholders drop cleanly. The page-side
  // `dropEmptySentences` mirrors the Swift engine's user-facing sentence-drop
  // behaviour.
  function interpolate(template, vars) {
    return template.replace(/\{(\w+)\}/g, function (_, key) {
      var v = vars[key];
      if (v === undefined || v === null || v === "") return "";
      return String(v);
    });
  }

  // Sentence-drop: split a rendered string on ". " and drop any sentence
  // that still contains an unsubstituted `{...}`. Re-join with ". ".
  // Mirrors `interpolate()`'s user-facing output in GamesRoom/Services/MascotEngine.swift.
  function dropEmptySentences(rendered) {
    var parts = rendered.split(". ");
    var kept = parts.filter(function (s, i) {
      // The last fragment has no trailing space — if it still contains `{`,
      // drop it too. Otherwise keep.
      if (i === parts.length - 1) {
        return s.indexOf("{") === -1;
      }
      return s.indexOf("{") === -1;
    });
    return kept.join(". ");
  }

  // ── 5. Public exports ────────────────────────────────────────────────
  root.GamesRoomVoices = {
    PERSONALITIES:     PERSONALITIES,
    IDEOLOGIES:        IDEOLOGIES,
    PERSONALITY_LABEL: PERSONALITY_LABEL,
    IDEOLOGY_LABEL:    IDEOLOGY_LABEL,
    IDEOLOGY_HEAD:     IDEOLOGY_HEAD,
    VOICE_HINT:        VOICE_HINT,
    MATRIX:            MATRIX,
    interpolate:       interpolate,
    dropEmptySentences: dropEmptySentences
  };
})(typeof window !== "undefined" ? window : this);
