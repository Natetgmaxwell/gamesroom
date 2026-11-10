#!/usr/bin/env bash
# Before/after literal counts, 03-spacing.md method.
# scope: the audit's own file set - every .swift under GamesRoom/Views, plus
# GamesRoomWidgets/GamesRoomWidgets.swift and GamesRoomWatch/GamesRoomWatchApp.swift.
# (Theme.swift and GamesRoom/Auth/SignInView.swift are outside the audit's table.)
#
# usage: s4-count-compare.sh <before-root> <after-root>
before="$1"; after="$2"
list_files() {
  ( cd "$1" && { find GamesRoom/Views -name '*.swift'; printf '%s\n' GamesRoomWidgets/GamesRoomWidgets.swift GamesRoomWatch/GamesRoomWatchApp.swift; } | sort )
}
count() { # $1=file $2=pattern -> one bare number
  local n
  n=$(grep -cE "$2" "$1" 2>/dev/null | head -1 | tr -d '[:space:]')
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}
printf "%-46s %5s %5s %5s %5s %5s %5s | %5s %5s %5s %5s %5s %5s\n" \
  file sp_b pd_b sf_b rd_b op_b fr_b sp_a pd_a sf_a rd_a op_a fr_a
tb_sp=0; tb_pd=0; tb_sf=0; tb_rd=0; tb_op=0; tb_fr=0
ta_sp=0; ta_pd=0; ta_sf=0; ta_rd=0; ta_op=0; ta_fr=0
for f in $(list_files "$before"); do
  b_sp=$(count "$before/$f" 'spacing: [0-9]'); b_pd=$(count "$before/$f" '\.padding\((\.[a-z]+, )?[0-9]')
  b_sf=$(count "$before/$f" '\.system\(size:'); b_rd=$(count "$before/$f" 'cornerRadius: [0-9]')
  b_op=$(count "$before/$f" 'opacity\([0-9]'); b_fr=$(count "$before/$f" '\.frame\((width|height|maxWidth): [0-9]')
  a_sp=$(count "$after/$f" 'spacing: [0-9]'); a_pd=$(count "$after/$f" '\.padding\((\.[a-z]+, )?[0-9]')
  a_sf=$(count "$after/$f" '\.system\(size:'); a_rd=$(count "$after/$f" 'cornerRadius: [0-9]')
  a_op=$(count "$after/$f" 'opacity\([0-9]'); a_fr=$(count "$after/$f" '\.frame\((width|height|maxWidth): [0-9]')
  if [ "$b_sp$b_pd$b_sf$b_rd$b_op$b_fr$a_sp$a_pd$a_sf$a_rd$a_op$a_fr" = "000000000000" ]; then continue; fi
  printf "%-46s %5s %5s %5s %5s %5s %5s | %5s %5s %5s %5s %5s %5s\n" "$f" \
    "$b_sp" "$b_pd" "$b_sf" "$b_rd" "$b_op" "$b_fr" "$a_sp" "$a_pd" "$a_sf" "$a_rd" "$a_op" "$a_fr"
  tb_sp=$((tb_sp+b_sp)); tb_pd=$((tb_pd+b_pd)); tb_sf=$((tb_sf+b_sf))
  tb_rd=$((tb_rd+b_rd)); tb_op=$((tb_op+b_op)); tb_fr=$((tb_fr+b_fr))
  ta_sp=$((ta_sp+a_sp)); ta_pd=$((ta_pd+a_pd)); ta_sf=$((ta_sf+a_sf))
  ta_rd=$((ta_rd+a_rd)); ta_op=$((ta_op+a_op)); ta_fr=$((ta_fr+a_fr))
done
printf "%-46s %5s %5s %5s %5s %5s %5s | %5s %5s %5s %5s %5s %5s\n" \
  "TOTAL" "$tb_sp" "$tb_pd" "$tb_sf" "$tb_rd" "$tb_op" "$tb_fr" \
  "$ta_sp" "$ta_pd" "$ta_sf" "$ta_rd" "$ta_op" "$ta_fr"
