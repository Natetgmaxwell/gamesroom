# Casino Vision Probe Report

> **Status:** PROBE COMPLETE — synthetic + stress corpus; real-photo corpus pending
> **Date:** 2026-08-10
> **Host:** macOS 26, Swift 6.2.4, Vision.framework + CoreML.framework (CommandLineTools SDK)
> **Tool:** `Tools/CasinoVisionProbe` (out-of-tree SwiftPM executable, per roadmap Q-WAVE-3-PROBE-HARNESS default (a))

## TL;DR

The naive on-device approach (`VNDetectRectanglesRequest` + hue
heuristic) **fails**: it hallucinates rectangles on plain felt and
scores precision 0.394 on the synthetic corpus. A color-segmentation
detector (mask chip-like pixels → connected components → merge into
stacks) **passes**: recall 1.000, precision 1.000, color accuracy
1.000, mean IoU 0.941 on the same corpus, with zero detections on
pure felt.

**The on-device path is viable in principle — but only on green felt. The
stress corpus (non-green felt variants) drops recall to 0.388, and the
real-photo corpus (10 photos, actual room + chip set) is still the
moment of truth before locking F-CAS-02.**

## Why this probe exists

`projects/casino-pack-vision-architecture` (gbrain) lists the
on-device Vision feasibility probe as the open gate:

> "run Core ML stack-segmentation on real chip photos in normal room
> lighting. If <80% reliable, spec needs hybrid fallback."

The V0.3 calibration addendum calls it "the single highest-leverage
action in the casino pack right now" — it validates or invalidates
the entire on-device spec. The roadmap (Wave 3) dispatched this probe
with the decision matrix below.

## Method

1. Built `Tools/CasinoVisionProbe` — a standalone SwiftPM executable
   (no Xcode target, runs on any Mac with Swift).
2. Generated a synthetic corpus: 10 images, 1080x1080, 1-4 chip stacks
   per image (28 stacks total), 5 colors (red/blue/green/black/white),
   felt-like textured background, ground truth written as
   `ground-truth.json`.
3. Ran two detector variants over the corpus:
   - `rectangles`: `VNDetectRectanglesRequest` + hue classification +
     height-based count (the app's documented on-device approach).
   - `segmentation`: chip-likeness mask (bright / dark / non-green
     hue) → 3x3 dilation → connected components → vertical merge into
     stacks → mean-hue/value classification → height-based count.
4. Scored both with stack-level IoU >= 0.3 matching (PASCAL VOC).

## Results

### Segmentation detector (recommended)

| Metric | Value |
|--------|-------|
| Recall | **1.000** (28/28) |
| Precision | **1.000** (0 FP) |
| Color accuracy | **1.000** |
| Count MAE | 3.54 chips |
| Mean IoU | 0.941 |
| Pure-felt FPs | **0** |

### Rectangle detector (naive)

| Metric | Value |
|--------|-------|
| Recall | 0.929 (26/28) |
| Precision | **0.394** (40 FP) |
| Color accuracy | 0.808 |
| Count MAE | 3.31 chips |
| Mean IoU | 0.731 |
| Pure-felt FPs | **6-9 per frame** |

### Head-to-head

| Dimension | rectangles | segmentation |
|-----------|-----------|--------------|
| Felt hallucination | 6-9 FPs on empty felt | 0 |
| Precision | 0.394 | 1.000 |
| Color accuracy | 0.808 | 1.000 |
| Localization (IoU) | 0.731 | 0.941 |
| Count MAE | 3.31 | 3.54 |

## Failure modes found (and fixed)

1. **Coordinate flip** — Vision returns bottom-left origin; the app's
   `BoundingBox` model is top-left. Ground truth must be written in
   the same convention or nothing matches.
2. **Felt hallucination** — `VNDetectRectanglesRequest` finds
   rectangle-like edges in felt texture. Saliency gating
   (`VNGenerateAttentionBasedSaliencyImageRequest`) did not fix it.
   Root fix: don't use rectangle detection at all.
3. **Saturation is not enough** — green felt is itself highly
   saturated (sat ~0.76). The mask must use value + hue, not
   saturation alone.
4. **Black chips are low-contrast** — black chip bodies are nearly
   identical to dark felt; only the rim passes the mask. Fix: 3x3
   dilation before labeling.
5. **Neutral chips have meaningless hue** — black and white chips
   both classify as "blue" by hue. Fix: classify by saturation first
   (low sat → split by value), hue only for saturated chips.
6. **Per-chip band splitting** — each chip's lighter center band is a
   separate component. Fix: merge components with overlapping
   x-intervals and small vertical gaps into one stack.

## Stress corpus (harder synthetic)

The synthetic corpus proved the pipeline on one felt color. Real rooms
vary, so a stress corpus was generated (`CasinoVisionProbe stress`,
24 frames, 1080x1080): 4 felt variants (baseline green, dark blue,
burgundy, light green), 2-6 stacks per frame, wider size range
(40-140 px wide, 20-200 px tall), per-image lighting perturbation
(0.7-1.15x), and 1 pure-felt adversarial frame per variant. 80 truth
stacks total.

### Segmentation detector on stress corpus

| Metric | Value |
|--------|-------|
| Recall | **0.388** (31/80) |
| Precision | **0.646** (17 FP) |
| Color accuracy | **1.000** |
| Count MAE | 5.48 chips |
| Mean IoU | 0.921 |
| Pure-felt FPs | 1 per non-green frame |

### The failure is felt color, not lighting or density

| Felt variant | Frames | Recall | FPs |
|--------------|--------|--------|-----|
| Green (baseline + light green) | 8 | **1.000** (31/31) | 1 |
| Dark blue | 6 | 0.000 (0/20) | 5 |
| Burgundy | 6 | 0.000 (0/20) | 5 |
| Light green | 4 | 1.000 (0/0 adversarial) | 0 |

The detector holds up under lighting perturbation, wider size range,
and denser stacks on green felt. On non-green felt it fails
completely: the felt itself passes the chip-likeness mask (non-green
hue), becomes one full-frame component at confidence 100, and
swallows every stack in the frame. This is the README's flagged known
limitation ("the segmentation mask assumes green felt") — now
measured.

**Implication:** the current detector is green-felt-only. A non-green
table (blue, red, black) is a hard failure mode, not a graceful
degradation. Re-tuning the hue-exclusion band per table color is
possible but adds a calibration step the spec does not currently
contain.

## Decision matrix (roadmap §Wave 3)

| Probe result | Path |
|--------------|------|
| >= 0.8 mAP across all 10 photos at confidence 0.5 | **F-CAS-02 stays deferred V0.9**; on-device Core ML is shippable |
| 0.5-0.8 mAP | F-CAS-02 stays core-only; ship with `<80% reliable` disclaimer + user-attestation fallback |
| < 0.5 mAP | **F-CAS-02 becomes Wave 3b** — hybrid cloud-vision fallback required |

## Verdict

**PARTIAL — synthetic PASS, stress FAIL on non-green felt, real photos
pending.**

The segmentation detector achieves the >= 0.8 bar on the original
synthetic corpus (1.000 across the board) and holds 1.000 recall on
green-felt stress frames under lighting perturbation, wider sizes,
and denser stacks. But the stress corpus exposes a hard boundary:
**on non-green felt the detector scores recall 0.000** — the felt
passes the chip-likeness mask and swallows every stack. Overall
stress recall 0.388, precision 0.646.

Per the decision matrix, the stress corpus result (< 0.5 recall) maps
to **F-CAS-02 becomes Wave 3b — hybrid cloud-vision fallback
required** — *unless* the real table is green felt, which the
real-photo corpus is the only way to establish. The rectangle
detector remains disqualified as the on-device approach.

**Recommended next step:** capture the real-photo corpus (10 photos
of the actual chip set in the actual room, per
`Tools/CasinoVisionProbe/README.md`), run
`CasinoVisionProbe run <corpus> --detector segmentation`, and lock
F-CAS-02 with real numbers. If the real table is green felt, the
on-device path is plausibly shippable; if not, plan Wave 3b (hybrid
cloud-vision) and add per-table-color calibration to the spec.

## Reproduction

```bash
cd Tools/CasinoVisionProbe
swift build
BIN="$(swift build --show-bin-path)/CasinoVisionProbe"
"$BIN" generate /tmp/casino-probe-corpus 10 1080 1080
"$BIN" run /tmp/casino-probe-corpus --detector segmentation
"$BIN" run /tmp/casino-probe-corpus --detector rectangles 0.3
"$BIN" stress /tmp/casino-stress-corpus 6 1080 1080
"$BIN" run /tmp/casino-stress-corpus --detector segmentation
```

All numbers above reproduce from these commands (seeded RNG, stable
corpora).
