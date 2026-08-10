# Casino Vision Probe

Out-of-tree SwiftPM executable that answers the casino pack's open
architecture question: **can on-device chip-stack detection work well
enough to ship, or does the spec need a hybrid cloud-vision fallback?**

This is a probe, not production code. It does not link into the
GamesRoom Xcode target. It exists to produce the decision data in
`docs/casino-vision-probe-report.md`.

## Build & run

```bash
cd Tools/CasinoVisionProbe
swift build
BIN="$(swift build --show-bin-path)/CasinoVisionProbe"

# 1. Generate a synthetic smoke-test corpus (10 images, 1080x1080)
"$BIN" generate /tmp/casino-probe-corpus 10 1080 1080

# 2. Run the probe over a corpus
"$BIN" run /tmp/casino-probe-corpus --detector segmentation
"$BIN" run /tmp/casino-probe-corpus --detector rectangles 0.3

# 3. Inspect one image (detections + ground truth side by side)
"$BIN" debug /tmp/casino-probe-corpus/synthetic-00.png --detector segmentation

# 4. Machine-readable report
"$BIN" run /tmp/casino-probe-corpus --detector segmentation --json /tmp/report.json

# 5. Eyeball real photos with no annotation (zero-friction test)
"$BIN" scan /tmp/casino-real-corpus --detector segmentation
```

## Commands

| Command | Purpose |
|---------|---------|
| `generate <dir> [count] [w] [h]` | Draw synthetic chip-stack images + `ground-truth.json` |
| `stress <dir> [frames-per-variant] [w] [h]` | Draw harder corpus: 4 felt variants, lighting perturbation, pure-felt adversarial frames |
| `run <dir> [--detector rectangles\|segmentation] [--json out.json] [threshold]` | Run detector over corpus, print metrics |
| `scan <dir> [--detector segmentation\|rectangles]` | Run detector over a photo folder with no ground truth — prints what it sees per image |
| `debug <image> [--detector ...] [threshold]` | Print detections + truth for one image |

## Detector variants

### `rectangles` — `VNDetectRectanglesRequest` + hue heuristic

The naive approach: find rectangles, classify each by dominant hue,
estimate count from box height.

**Probe verdict: not viable.** Hallucinates 6-9 rectangles on a
pure-felt frame with zero chips (measured). Precision 0.394 on the
synthetic corpus. The felt texture is full of rectangle-like edges.

### `segmentation` — color-segmentation + connected components

The robust approach: mask chip-like pixels (bright, dark, or
non-green-hue — felt is mid-value green and fails all three), dilate,
label connected components, merge vertically-adjacent components into
stacks, classify by mean hue/value, estimate count from stack height.

**Probe verdict: PASS on synthetic corpus.** Recall 1.000, precision
1.000, color accuracy 1.000, mean IoU 0.941. Zero detections on pure
felt.

## Metrics

- **Recall / precision** — stack-level, IoU >= 0.3 match (PASCAL VOC)
- **Color accuracy** — correct color / matched detections
- **Count MAE** — mean absolute error in chip count per matched stack
- **Mean IoU** — localization quality

## Real-photo corpus (the gold standard)

The synthetic corpus proves the pipeline; it does not prove real-world
accuracy. Before locking the F-CAS-02 decision, capture a real corpus:

1. `mkdir -p /tmp/casino-real-corpus`
2. Photograph 10 chip stacks in normal room lighting (the actual room,
   the actual chip set, phone camera, no special setup).
3. Name files `real-00.png` ... `real-09.png` (or jpg).
4. Write `ground-truth.json` next to them — one entry per image, one
   `StackTruth` per stack: normalized `x/y/w/h`, `color`
   (red/blue/green/black/white), `count`.
5. `"$BIN" run /tmp/casino-real-corpus --detector segmentation`

**Zero-annotation first pass:** if you just want to see what the
detector sees before annotating, drop the photos in a folder and run
`"$BIN" scan <dir> --detector segmentation` — it prints per-image
stacks (box, color, count, confidence) with no ground truth required.
This is the fastest way to eyeball real-world behavior; annotate only
if the eyeball looks promising.

Decision matrix (from the roadmap):

| Result | Path |
|--------|------|
| >= 0.8 recall+precision+color at conf 0.5 | F-CAS-02 stays deferred; on-device Core ML is shippable |
| 0.5-0.8 | Ship on-device with `<80% reliable` disclaimer + user-attestation fallback |
| < 0.5 | F-CAS-02 becomes Wave 3b — hybrid cloud-vision fallback required |

## Known limitations

- Count estimation (stack height / 10px) is the weakest metric
  (MAE ~3.5 chips on synthetic). Real chips have consistent thickness;
  calibrate the divisor against the real chip set.
- The segmentation mask is background-adaptive (estimates table
  color from the frame border), so it is not tied to green felt.
  Measured on the stress corpus (6 frames x 4 felt variants):
  recall 0.975, precision 1.000, color 0.974 across
  green/dark-blue/burgundy/light-green felts.
- Synthetic chips are drawn with a lighter center band; real chips
  vary (solid, edge spots, inlays). The real-photo corpus is the
  moment of truth.
