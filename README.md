# ge-fieldmap-fsl

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![FSL](https://img.shields.io/badge/FSL-6.x-orange.svg)
![Shell](https://img.shields.io/badge/shell-bash-lightgrey.svg)

Computes a usable B0 fieldmap for FSL from
**GE-scanner-style two-echo fieldmap acquisitions** (separate
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

## The method

1. Brain-extract the magnitude image (tight extraction, then lightly erode
   the mask to remove noisy edge voxels).
2. Form the **wrapped** phase difference: `phase2 - phase1`, re-wrapped
   into [-π, π). This is the same as `angle(exp(i·phase2) · conj(exp(i·phase1)))`,
   and it has one consistent wrap count by construction.
3. Unwrap that single difference image with `prelude`.
4. Remove any remaining whole-wrap offset (2π·k), using the in-brain median.
5. Divide by the echo time difference to get the fieldmap in rad/s.

Only core FSL tools (`bet`, `prelude`, `fslmaths`, `fslstats`) are used.

## Changelog: v1 had a bug -- please re-run if you used it

**v1 (September 2026) unwrapped `phase1` and `phase2` separately and then
subtracted them.** That is wrong. `prelude` picks each image's global 2π
offset independently, so the two unwrapped images can disagree by a constant
2π·k. The resulting fieldmap is then shifted by k/ΔTE Hz everywhere -- 500 Hz
per wrap at ΔTE = 2 ms.

On ds000201 this affected **71 of 142 sessions** (offsets of 1 to 4 wraps).
Those 71 sessions contained **all 56** catastrophic registration failures;
the 71 unaffected sessions had none. v2 (this version) gives fieldmaps that
match a reconstruction from the dataset's real/imaginary source data to
within 0.014 rad/s (median), and centres every tested session within ~20 Hz
of zero.

If you ran v1, check the in-brain median of your fieldmap: a value near a
multiple of 2π/ΔTE (≈ 3142 rad/s at ΔTE = 2 ms) means it was hit.

## Requirements

- FSL installed and on your `PATH` (tested with FSL 6.x)
- `python3` (only used for arithmetic; any version works)

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

Output: `sub-01_fieldmap_rads.nii.gz`, in rad/s, **in fieldmap space**.

## Applying it: put the fieldmap on the EPI grid first

`fugue --loadfmap` does **not** resample. It pairs fieldmap and EPI voxels
by index. If the grids differ (on ds000201 the fieldmap is 64×64 at 3.75 mm
and the BOLD is 128×128 at 1.875 mm), the shift map lands on one corner
quarter of the EPI and the rest is left uncorrected, with no error or
warning.

Register the fieldmap to the EPI and resample it first. One way, via the T1:

```bash
# fieldmap magnitude -> T1
flirt -in fmap_mag_brain -ref T1_brain -dof 6 -omat fmap2str_init.mat
flirt -in fmap_mag -ref T1 -dof 6 -init fmap2str_init.mat -omat fmap2str.mat -nosearch
# EPI -> T1 (e.g. BBR), inverted, then chained: fieldmap -> EPI
convert_xfm -omat str2epi.mat -inverse epi2str.mat
convert_xfm -omat fmap2epi.mat -concat str2epi.mat fmap2str.mat
applywarp -i sub-01_fieldmap_rads -r mean_epi --premat=fmap2epi.mat -o fmap_rads_epi

fugue --in=mean_epi --loadfmap=fmap_rads_epi \
      --dwell=<EffectiveEchoSpacing_from_func_json> \
      --unwarpdir=<y_or_y-> -u mean_epi_unwarped
```

`epi_reg --fmap=...` does this chain for you. If you use it, check that its
output matrix actually differs from a run without `--fmap`.

**Check the unwarp direction.** Run both `y` and `y-` and keep the one that
improves registration. On GE data the polarity in the BIDS JSON is not
always right.

**Always compare against no correction.** Compute a BBR cost (or similar)
for corrected vs. uncorrected registration in each subject before trusting
the correction.

## Status on ds000201

With both bugs above fixed, whether fieldmap correction improves
registration on ds000201 is being re-tested across all 142 sessions. This
section will be updated with the results.

## License

MIT
