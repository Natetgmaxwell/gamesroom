# Games Room: Friendship as the Substrate (SPEC addendum)

> Status: **locked.** This addendum makes the friendship-formation canon operational.
> It is the substrate the ledger-as-social-surface and multi-room specs derive from.
> It sits under V0.53: the vision memo says *what* the product is against; this says
> *how* the product grows the thing it exists to grow: friendship.
>
> Feeds: [[docs/vision/V0.53_VISION.md]] (vision memo, locked),
> [[docs/vision/RESEARCH_BRIEF_COUNTER_TREND.md]] (research brief, locked).
> Canon: Currier, five conditions (NFX, 2020); Aristotle, *Nicomachean Ethics* VIII–IX.
> Hour-rule attribution: **Hall** (Univ. Kansas, JSPR 2019), not Waldinger.

---

## 0. The substrate thesis

Games Room does not make friends. It makes the conditions under which friends
get made, then gets out of the way. The five conditions and the three philia
tiers are the substrate; the rooms, the ledger, the seasons, and the nights are
the surface that sits on it. If a surface choice serves the substrate, it stays.
If it serves the app's time-in-screen, it fails the product.

Three rules bind every principle below:

1. **The metric fires only when a night happened.** No-show, a friend who
   showed up, a chip swing across three rooms: real events. Accounts, sessions,
   time-in-app are not events. (V0.53, research brief §6.)
2. **The app stays below the table.** It plans the night; the room runs it. A
   feature that keeps a user looking at the screen instead of the people across
   the table fails the product. (V0.53 §4.)
3. **The app cannot manufacture any of the five conditions.** It can only
   remove the friction in the way of them. The moment the app tries to *cause*
   the friendship, it becomes the medium, and the medium gets hollow or mean.
   (Research brief §6: IRL, Yik Yak.)

---

## Part 1: Currier's five conditions

Each condition below is one spec block: what we build (or build against), the
signal we watch, the test that tells us we are getting it wrong, and the line
we will not cross.

### 1.1 Repeated unplanned interactions

**The spec.** Games Room cannot manufacture unplanned encounters; that is a
dorm or an office, not an app. What it can do is guarantee the *repeated* half,
which is the half that dies in the group chat. Every room ships with a recurring
slot (the Weekly Default, "Thursdays at 7") the host can move but never has to
schedule. The repetition is the app's job, so the unplanned social (arrivals,
pre-game, the side conversation) is free to happen inside the room. Games Room
turns "repeated unplanned" into "repeated, scheduled, unplanned inside it."

**Build against:** event-by-event discovery. A marketplace of one-off nights
never accumulates the repetition the condition needs.

**Signal:** same-room recurrence. Median consecutive nights per member, per room;
weeks the room ran back to back; members seen at the table 3+ times (the
Health-Floor Pulse). Hall's curve says 90–200 hours with someone is the shift
toward real friendship; the recurring slot is the only mechanic that reliably
piles up those hours.

**Violation test:** the cadence holds but no relationship forms: members show
up, play, leave, and never carry the room into their other circles. Repetition
without bonding is the app scheduling meetups, not friendships. Also a violation:
we ever replace the recurring slot with "browse nights and RSVP ad hoc."

**The line we will not cross:** no re-engagement nudges ("you haven't been
back"). A gap is not a failure; the recurring slot is still there. The app does
not chase.

### 1.2 High overlap (shared connections)

**The spec.** Friendship forms fastest in a bounded circle where people already
share connections. Games Room makes the room a bounded circle, and grows it only
through friends-of-friends. Invite tiers keep the gate real: tier 1 the host
invites directly; tier 2 a member's friend needs one co-host approval; tier 3 an
open invite code usable only by the invitee. Overlap across rooms is the strong
signal: one friend who sits with you in two rooms counts far more than a
hundred strangers in one.

**Build against:** open discovery, invite-link virality, a public directory.
The room is a friend circle, not a random crowd.

**Signal:** overlap density: members of room A who also sit in room B; a new
member's shared-connection count at the moment they join; the ratio of
tier-2+ joins to total joins. Bounded density is what produces trust.

**Violation test:** a room whose members share no connections outside it: a
collection of strangers who merely co-attend. That is a Meetup-style open group,
not a friend circle, and the friendship-formation rate collapses with the
overlap.

**The line we will not cross:** no open invite links, no public directory, no
viral expansion. Expansion happens only through a vetted friend, never through a
link a stranger can pass on.

### 1.3 Transition period (life-stage crossroads)

**The spec.** Friendships form fastest at life transitions: a new city, a new
job, a move away from an old circle. Games Room mostly needs to *not* block this
condition. A recurring game night is a stable node in the middle of a churning
life: the one thing that does not change when everything else does. So the
product must (a) let a member into a room at any point with low friction: a
friend vouches via tier 2; and (b) let a member lapse without penalty, because
real friendships survive gaps and come back to a standing weekly slot.

**Build against:** punishing absence. A "you're losing your streak" mechanic, a
seat that is stripped the moment someone misses, a shame layer: all of it kills
the transition-anchor property.

**Signal:** a member who joined during a life change and stayed; a room that
survives a member leaving the city (the ledger and the friendship persist
across rooms); members who return after a multi-week gap and slot straight back
into the cadence.

**Violation test:** the app treats a lapse as a failure: deranks a returning
member, clears their history, shames them. Real friendships tolerate gaps; if
the product does not, it is not serving the substrate.

**The line we will not cross:** no "come back" engagement, no streak-keeping, no
absence penalties beyond the seat deposit (which is about the *forfeit being
lost*, not a score against the absent member).

### 1.4 High density (proximity)

**The spec.** Density is bodies at a real table. This is the whole counter-trend:
the app brings people to physical co-presence, then gets out of the way. The
anti-flake mechanism is the density machine. The deposit-forfeit is the
commitment device; the no-show tax (forfeited chips flowing into the next
night's pot as a public record) makes showing up the default and makes absence a
visible, room-wide event. The public yes-list makes RSVP a statement of presence,
not a private click.

**Build against:** any success metric that counts without bodies. Active users,
sessions, time-in-app, "viewed the night": all of it.

**Signal:** nights actually attended. The only number the product truly cares
about is nights-that-happened, and it fires only when a night happened. No-show
rate is watched as a health sign, not as a "session."

**Violation test:** a member can "participate" without being present: a
spectator mode, a remote seat, a metric that rewards being online with the room
instead of at the table. That is density gone fake, and it is the exact failure
that killed IRL.

**The line we will not cross:** no live spectator mode, no remote play, no
"watch the night unfold." If you are not at the table, you get the recap, not
the stream. (V0.53 §4.)

### 1.5 Shared hardship (shared challenge / shared experience)

**The spec.** The deepest friendships form through shared struggle or shared
experience: the bad beat, the come-from-behind win, the season that ended in
tears and laughing. The game *is* the shared experience; Games Room's job is to
keep the stakes real and to honor the social behavior, not the meta-game. The
Good Sport principle rewards the player who loses well; the season arc gives the
hardship a container: a losing season is a shared hardship that binds a room
tighter than a winning one. The ledger keeps the real swings so the shared
history is legible.

> Attribution note: "shared hardship" is the paraphrase of NFX's broader
> "network challenge / shared experience" framing. Use it, but know it stands
> for shared challenge, not misery.

**Build against:** sanding down the stakes. Auto-win mechanics, no downside,
leaving mid-game without consequence, stripping the real swings out of the
ledger. Remove the hardship and you remove the bonding mechanism.

**Signal:** members who shared a losing season stay in the room the next season;
the comeback narrative (a member who went deep negative and fought back);
cross-session bonds that survive a bad night. The climbing-gym analog is trust:
a member who played badly and came back anyway is the strongest bond in the
room.

**Violation test:** the product optimizes away the struggle: makes winning too
easy, removes downside, lets players bail without a trace, or turns the ledger
into a flat scoreboard with no real swings. The shared experience dies with the
stakes.

**The line we will not cross:** no consolation prizes that erase the loss, no
mechanics that remove downside. The loss stays real; the *friendship* is what
softens it, and that is the app's quiet job.

---

## Part 2: Aristotle's three philia tiers

The tiers are the destination. Games Room's long job is to move members up the
tier ladder, from utility to pleasure to virtue, by deepening the shared
history, not by locking anyone in. Each tier below is a spec block.

### 2.1 Utility: dissolves when the use ends

**The spec.** A utility room is one people attend because they get something:
chips, a network, a favor owed. Games Room does not chase these rooms and does
not grieve them. A room that dissolves when the use ends has done its job and
moved on. The product's posture toward utility is: let it end cleanly. Do not
manufacture retention to hold a room that has nothing to hold it.

**Build against:** forced retention. Leaving friction, "are you sure?" walls,
invisible exits, a guilt trip when someone walks. A locked-in member is a utility
friendship the product is trying to keep alive by force, and it will collapse
the same way.

**Signal:** a room that naturally dissolves (members drift out as the use ends).
This is an acceptable outcome, not a failure.

**Violation test:** the product keeps a hollow room alive with engagement
mechanics: nudges, rewards for staying, a "don't break the chain" pressure.
That is manufacturing utility, and it is the medium trap.

**The line we will not cross:** no retention mechanics, no "you haven't been
back," no leaving friction. A room ends; the ledger and the friendships inside
it persist.

### 2.2 Pleasure: dissolves when the fun ends

**The spec.** The recurring weekly game night lives here. Members show up because
it is fun, and the fun is the glue. Games Room's job is to make the fun durable
and to make the room's identity carry the pleasure: the house rule, the
signature game, the mascot voice, the ceremony. The pleasure tier is where most
rooms live, and the weekly cadence is what keeps the fun from fading into
habit.

**Build against:** letting the fun erode into obligation. A room that stops being
fun and becomes a standing chore will dissolve, and it should; the product must
not paper over a loss of fun with points.

**Signal:** weekly retention while the room is fun; the cadence holds without the
host doing forever-work (the Weekly Default does the scheduling). The pleasure
tier is healthy when members come back for the night, not for the bookkeeping.

**Violation test:** the room runs on autopilot and the fun is gone: members
attend out of duty, the game is a default no one chose, the ceremony is silent.
The app kept the calendar but lost the pleasure, and a pleasure-room with no
pleasure is a room waiting to die.

**The line we will not cross:** no points-for-attending, no streaks that prop up
a joyless room. The fun is the product's reason to exist at this tier; the app
does not substitute for it.

### 2.3 Virtue: mutual wishing of good for its own sake, persists

**The spec.** The deepest tier: members who wish each other well for their own
sake, who stay friends after the game and after the room. Games Room reaches
this tier by accumulating shared history across time, rooms, and seasons. The
ledger is the record of that history; cross-room overlap is the signal that a
friendship has generalized beyond one table; the season arc is the narrative
container that makes the history feel like a story, not a log. Virtue needs
time and repeated shared experience, which the recurring slot and the ledger
are exactly built to accumulate.

**Build against:** treating every room the same. If the product cannot tell a
pleasure room from a virtue room, it will under-serve the deep one: it will
keep deepening the shallow and leave the deep friendships without the surface
they need (the ledger, the cross-room record, the ceremony).

**Signal:** cross-room membership that persists; ledger depth that spans
seasons; members who remain friends after a room ends. A friend-of-friend who
shows up, a chip swing across three rooms, a member seen at the table 3+ times.
These are the real events that mark the climb toward virtue.

**Violation test:** the product makes the friendship itself instrumental: keep
your streak to win the prize, a leaderboard where the *relationship* is the
points. That turns a virtue friendship into a utility one: members using each
other for the score. It is the precise opposite of wishing the other's good
for its own sake.

**The line we will not cross:** the ledger rewards the *game*, never the
*friendship*. The social behavior (Good Sport) is honored by the room's voice,
not counted as a score.

---

## Part 3: The mirror, what NOT to do

The single risk is becoming the medium. Each of the five conditions and three
tiers has a betrayal, and they all collapse into one: **the app starts counting
itself instead of the nights.**

| Substrate principle | The betrayal | Failure it produces |
|---|---|---|
| Repeated interaction | Event marketplace, "browse and RSVP" | No accumulated hours, no cadence |
| High overlap | Invite-link virality, open discovery | Strangers in a room, trust collapses |
| Transition period | Absence penalties, streak pressure | Lapses become wounds, no coming back |
| High density | Remote seats, spectator mode, fake metrics | "Presence" without bodies, the IRL hollowing |
| Shared hardship | Sanded-down stakes, no downside | The shared experience dies with the stakes |
| Utility | Forced retention, leaving friction | A locked-in member, a hollow room |
| Pleasure | Points-for-attending, streak props | A joyless room kept alive by numbers |
| Virtue | Friendship counted as a score | Members use each other for the points |

**The test that holds all of them:** *if a feature keeps a user looking at the
screen instead of the people across the table, it fails the product.* (V0.53,
verbatim.) A feature that would survive on a twice-a-week user who is only ever
in the app to get to the table is a feature that serves the substrate. Anything
that needs more time-in-app to justify itself is the medium creeping back in.

**The host's test (Carnegie, 2026-08-19):** *if a move keeps the host looking
at the technique instead of the members, it fails the room.* Same shape, same
severity, same direction as the product test. The host is the only human voice
in the room; the mascot is the only system voice. A host who starts watching
their own technique — the praise, the opener, the override — instead of the
people across the table has become the medium in human form. The product test
guards the app; the host test guards the host. Both must hold.

---

## Part 4: Where this lands (handoff to the next two specs)

This addendum is the substrate the two downstream writing specs derive from.
Do not re-derive the canon in those specs; reference this file.

- **Ledger-as-social-surface** (the season-arc, awards, shareable stat card
  spec) must honor 2.3 and 1.5: the ledger rewards the game, never the
  friendship; awards honor the social behavior (Good Sport) without counting it.
  The shareable stat card is the pleasure-tier artifact that carries the memory
  outside the app; it must never become a badge shelf or a score.
- **Multi-room-as-social-object** (the room-graph spec) is the 1.2 and 2.3
  surface: one friend across two rooms is the strong overlap signal; the invite
  tiers (1 host, 2 member+approval, 3 open-by-invitee) are the gate that keeps
  overlap real. The room graph is the substrate made visible.

## Sources

- Currier, "Your Life Is Driven by Network Effects," NFX 2020: five
  conditions; the shared-hardship naming is a paraphrase of its "shared
  challenge / experience" framing.
- Aristotle, *Nicomachean Ethics* VIII–IX: utility, pleasure, virtue.
- Hall, J. (Univ. Kansas, JSPR 2019): the 50/90/200-hour friendship curve.
- Locked feeds: `docs/vision/V0.53_VISION.md`, `docs/vision/RESEARCH_BRIEF_COUNTER_TREND.md`.
