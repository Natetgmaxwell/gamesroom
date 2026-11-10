#!/usr/bin/env bash
# Whole-tree literal counts, the 03-spacing.md method applied to every .swift file
# in the tree (Views + Components + widgets + watch + root). Prints per-file rows
# for every file with at least one hit, then a total row.
#
# usage: s4-count-all.sh <root>
root="$1"
cd "$root" || exit 2
printf "%-46s %5s %5s %5s %5s %5s %5s\n" file spacing padding sysFont radius opacity frame
total_spacing=0; total_padding=0; total_sys=0; total_radius=0; total_opacity=0; total_frame=0
while read -r f; do
  sp=$(grep -cE 'spacing: [0-9]' "$f")
  pd=$(grep -cE '\.padding\((\.[a-z]+, )?[0-9]' "$f")
  sf=$(grep -cE '\.system\(size:' "$f")
  rd=$(grep -cE 'cornerRadius: [0-9]' "$f")
  op=$(grep -cE 'opacity\([0-9]' "$f")
  fr=$(grep -cE '\.frame\((width|height|maxWidth): [0-9]' "$f")
  [ "$sp$pd$sf$rd$op$fr" = "000000" ] && continue
  printf "%-46s %5s %5s %5s %5s %5s %5s\n" "${f#./}" "$sp" "$pd" "$sf" "$rd" "$op" "$fr"
  total_spacing=$((total_spacing+sp)); total_padding=$((total_padding+pd))
  total_sys=$((total_sys+sf)); total_radius=$((total_radius+rd))
  total_opacity=$((total_opacity+op)); total_frame=$((total_frame+fr))
done < <(find . -name '*.swift' -not -path './.archive/*' | sort)
printf "%-46s %5s %5s %5s %5s %5s %5s\n" "TOTAL" "$total_spacing" "$total_padding" "$total_sys" "$total_radius" "$total_opacity" "$total_frame"
