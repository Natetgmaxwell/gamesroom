#!/usr/bin/env bash
# Emits the markdown row set for S4_REPORT.md: one row per file, "before -> after"
# per pattern, plus a totals row.
before="/Users/nathanmaxwell/Projects/games-room/.maestro/playbooks/Working/before"
after="/Users/nathanmaxwell/Projects/worktrees/s4/finish"
list_files() {
  ( cd "$1" && { find GamesRoom/Views -name '*.swift'; printf '%s\n' GamesRoomWidgets/GamesRoomWidgets.swift GamesRoomWatch/GamesRoomWatchApp.swift; } | sort )
}
count() {
  local n
  n=$(grep -cE "$2" "$1" 2>/dev/null | head -1 | tr -d '[:space:]')
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}
B_sp=0; B_pd=0; B_sf=0; B_rd=0; B_op=0; B_fr=0
A_sp=0; A_pd=0; A_sf=0; A_rd=0; A_op=0; A_fr=0
for f in $(list_files "$before"); do
  b_sp=$(count "$before/$f" 'spacing: [0-9]'); b_pd=$(count "$before/$f" '\.padding\((\.[a-z]+, )?[0-9]')
  b_sf=$(count "$before/$f" '\.system\(size:'); b_rd=$(count "$before/$f" 'cornerRadius: [0-9]')
  b_op=$(count "$before/$f" 'opacity\([0-9]'); b_fr=$(count "$before/$f" '\.frame\((width|height|maxWidth): [0-9]')
  a_sp=$(count "$after/$f" 'spacing: [0-9]'); a_pd=$(count "$after/$f" '\.padding\((\.[a-z]+, )?[0-9]')
  a_sf=$(count "$after/$f" '\.system\(size:'); a_rd=$(count "$after/$f" 'cornerRadius: [0-9]')
  a_op=$(count "$after/$f" 'opacity\([0-9]'); a_fr=$(count "$after/$f" '\.frame\((width|height|maxWidth): [0-9]')
  [ "$b_sp$b_pd$b_sf$b_rd$b_op$b_fr$a_sp$a_pd$a_sf$a_rd$a_op$a_fr" = "000000000000" ] && continue
  short="${f#GamesRoom/Views/}"
  case "$short" in GamesRoomWidgets/*|GamesRoomWatch/*) short="${f}";; esac
  printf '| `%s` | %s -> %s | %s -> %s | %s -> %s | %s -> %s | %s -> %s | %s -> %s |\n' \
    "$short" "$b_sp" "$a_sp" "$b_pd" "$a_pd" "$b_sf" "$a_sf" "$b_rd" "$a_rd" "$b_op" "$a_op" "$b_fr" "$a_fr"
  B_sp=$((B_sp+b_sp)); B_pd=$((B_pd+b_pd)); B_sf=$((B_sf+b_sf))
  B_rd=$((B_rd+b_rd)); B_op=$((B_op+b_op)); B_fr=$((B_fr+b_fr))
  A_sp=$((A_sp+a_sp)); A_pd=$((A_pd+a_pd)); A_sf=$((A_sf+a_sf))
  A_rd=$((A_rd+a_rd)); A_op=$((A_op+a_op)); A_fr=$((A_fr+a_fr))
done
printf '| **Total** | **%s -> %s** | **%s -> %s** | **%s -> %s** | **%s -> %s** | **%s -> %s** | **%s -> %s** |\n' \
  "$B_sp" "$A_sp" "$B_pd" "$A_pd" "$B_sf" "$A_sf" "$B_rd" "$A_rd" "$B_op" "$A_op" "$B_fr" "$A_fr"
