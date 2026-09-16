# ge-fieldmap-fsl

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![FSL](https://img.shields.io/badge/FSL-6.x-orange.svg)
![Shell](https://img.shields.io/badge/shell-bash-lightgrey.svg)

Fixes a specific, undocumented gap in FSL: computing a usable B0 fieldmap
from **GE-scanner-style two-echo fieldmap acquisitions** (separate
`phase1`/`phase2` and `magnitude1`/`magnitude2` images), which
`fsl_prepare_fieldmap` does not natively support. Written and validated
against a real GE (Discovery MR750) dataset from
[OpenNeuro ds000201](https://openneuro.org/datasets/ds000201).

## The problem

FSL's own `fsl_prepare_fieldmap` is built around Siemens-style output: a
single, pre-combined phase-*difference* image plus one magnitude image.
Many GE scanners instead produce **two separate phase images at two
separate echo times** -- exactly the format found in several public BIDS
datasets (e.g. [OpenNeuro ds000201](https://openneuro.org/datasets/ds000201)).

Naively subtracting the two raw (wrapped) phase images to get a
"difference" produces incorrect values at phase wrap-around boundaries --
a subtle bug that's easy to miss and can silently corrupt distortion
correction in exactly the brain regions (frontal, temporal, near sinuses)
where it matters most.

## The fix

The correct order of operations, per FSL's own FUGUE documentation:

1. Brain-extract the magnitude image (tight extraction, then lightly erode
   the mask to remove noisy edge voxels).
2. Unwrap **each** phase image *separately* using FSL's `prelude`,
   referenced to the same magnitude image.
3. **Only then** subtract the two already-unwrapped images -- ordinary
   subtraction is now valid, since both inputs are continuous
   (non-wrapped) at this point.
4. Scale by the echo time difference to get the fieldmap in rad/s, ready
   for `fugue`.

This script automates exactly that sequence using only core FSL tools
(`bet`, `prelude`, `fslmaths`) -- no additional packages required.

## Requirements

- FSL installed and on your `PATH` (tested with FSL 6.x)
- `python3` (only used for one arithmetic step; any version works)

## Usage

```bash
chmod +x ge_fieldmap_correct.sh
./ge_fieldmap_correct.sh <phase1.nii.gz> <phase2.nii.gz> <magnitude1.nii.gz> <TE1_ms> <TE2_ms> <output_prefix>
```

Example, using BIDS-style filenames and echo times from the JSON sidecars:

```bash
./ge_fieldmap_correct.sh sub-01_phase1.nii.gz sub-01_phase2.nii.gz \
    sub-01_magnitude1.nii.gz 6.8 8.8 sub-01_fieldmap
```

Output: `sub-01_fieldmap_rads.nii.gz`, ready to use with `fugue`:

```bash
fugue --in=<your_epi_or_mean_func> \
      --dwell=<EffectiveEchoSpacing_from_func_json> \
      --loadfmap=sub-01_fieldmap_rads.nii.gz \
      --unwarpdir=<y_or_y-_check_your_phase_encoding_direction> \
      -u <output_unwarped.nii.gz>
```

## A note on phase image units

This script assumes your `phase1`/`phase2` images are already scaled to
radians (approximately -π to π), which is standard BIDS convention. The
script prints the actual value range so you can confirm this. If your
data is instead in raw scanner integer units, you'll need to rescale to
radians before running this script.

## Why this matters

This exact issue cost real, avoidable debugging time on a student research
project before the correct fix was identified. If you're hitting the same
wall, hopefully this saves you that time.

## What this script does NOT fix

This script only fixes the phase-unwrap-order bug described above. It does
**not** guarantee that the resulting fieldmap will actually improve your
registration -- on at least one real subject from ds000201 (sub-9048), a
fieldmap computed with this exact correct procedure still made BBR-based
functional-to-structural alignment measurably *worse* than doing no
distortion correction at all (BBR cost 0.489 corrected vs. 0.379
uncorrected), and stayed worse across every fieldmap-sign and unwarp-
direction combination tested, and across a dwell-time sweep from 0.25x to
3x the BOLD JSON's stated `EffectiveEchoSpacing` -- cost degraded
*monotonically* with correction magnitude, which points to the fieldmap
itself not reflecting real distortion for that subject/session rather than
any tunable sign or scaling bug.

Suspected root cause: this is GE (Discovery MR750) data acquired with
ASSET parallel imaging. `EffectiveEchoSpacing` for GE scanners is a
*derived* quantity, not a native DICOM field -- `dcm2niix`'s own
documentation describes the ASSET-aware calculation as producing
"counterintuitive results with fractional reduction factors"
([dcm2niix GE/README.md](https://github.com/rordenlab/dcm2niix/blob/master/GE/README.md)).
An independent team preprocessing this same OpenNeuro dataset with
fMRIPrep hit the identical symptom and abandoned GRE-fieldmap correction
for it entirely in favor of synthetic (SyN-based) distortion correction
([edickie/ds000201_preproc](https://github.com/edickie/ds000201_preproc)).

**Practical takeaway:** always compute a BBR-cost (or equivalent) sanity
check comparing corrected vs. uncorrected registration per-subject before
trusting a GE-derived fieldmap -- don't assume "ran without error" means
"actually improved alignment." This repo does not currently include a
fix for the underlying `EffectiveEchoSpacing` unreliability; if you hit
this, the validated fallback (per the above) is synthetic/fieldmapless
distortion correction rather than tuning this script's inputs further.

## License

MIT
