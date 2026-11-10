#!/usr/bin/env bash
# audit method (03-spacing.md), reproduced:
root="$1"
cd "$root" || exit 2
printf "%-46s %5s %5s %5s %5s %5s %5s\n" file spacing padding sysFont radius opacity frame
find GamesRoom/Views -name '*.swift' | sort | while read -r f; do
  printf "%-46s %5s %5s %5s %5s %5s %5s\n" "${f#GamesRoom/Views/}" \
    "$(grep -cE 'spacing: [0-9]' "$f")" \
    "$(grep -cE '\.padding\((\.[a-z]+, )?[0-9]' "$f")" \
    "$(grep -cE '\.system\(size:' "$f")" \
    "$(grep -cE 'cornerRadius: [0-9]' "$f")" \
    "$(grep -cE 'opacity\([0-9]' "$f")" \
    "$(grep -cE '\.frame\((width|height|maxWidth): [0-9]' "$f")"
done
