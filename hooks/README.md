# Games Room git hooks

Hooks are versioned here and wired per clone with (one-time):

    git config core.hooksPath hooks

Connor: run that line once after pulling this commit.

## Gates
- **Token cap / ratchet** — `.swift` files cap at 5,000 tokens (bytes/4 = 20,000 bytes). New over-cap files are blocked; existing over-cap files (RoomDetailView, main.swift, MascotEngine) may not *grow* — shrink or split them freely until they're under cap.
- **Ghost-dup reject** — staged paths matching `Name N.swift` (iCloud sync regrowth) never commit. cmp against the original, then delete.
