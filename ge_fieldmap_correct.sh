#!/bin/bash
# ge_fieldmap_correct.sh
#
# Computes an FSL-compatible B0 fieldmap (in rad/s, ready for FUGUE) from
# GE-scanner-style two-echo fieldmap acquisitions: separate phase1/phase2
# and magnitude1/magnitude2 images at two echo times, as delivered in many
# BIDS datasets (e.g. OpenNeuro ds000201).
#
# WHY THIS EXISTS:
# FSL's own fsl_prepare_fieldmap expects a single, pre-combined phase-
# difference image (the standard Siemens export format). It does NOT
# natively support two separate phase images at two echo times, which is
# what many GE scanners produce.
#
# METHOD (fixed in v2 -- see README "Changelog"):
#   1. Form the WRAPPED phase difference phase2 - phase1, re-wrapped into
#      [-pi, pi). This equals angle(exp(i*phase2) * conj(exp(i*phase1))) and
#      has a single, consistent wrap count by construction.
#   2. Unwrap that one difference image with `prelude`.
#   3. Remove any remaining whole-wrap offset (2*pi*k) using the in-brain
#      median, so the fieldmap is centred on 0.
#   4. Divide by the echo time difference to get rad/s.
#
# v1 of this script unwrapped phase1 and phase2 SEPARATELY and then
# subtracted them. That is wrong: prelude picks each image's global 2*pi
# offset independently, so the difference can be off by a constant 2*pi*k,
# i.e. k/dTE Hz everywhere (500 Hz per wrap at dTE = 2 ms). On ds000201 this
# hit 71 of 142 sessions and caused every catastrophic registration failure.
#
# REQUIREMENTS: FSL (bet, prelude, fslmaths, fslstats) on PATH, and python3
# for two lines of arithmetic.
#
# USAGE:
#   ./ge_fieldmap_correct.sh <phase1.nii.gz> <phase2.nii.gz> \
#       <magnitude1.nii.gz> <TE1_ms> <TE2_ms> <output_prefix>
#
# EXAMPLE (BIDS-style filenames):
#   ./ge_fieldmap_correct.sh sub-01_phase1.nii.gz sub-01_phase2.nii.gz \
#       sub-01_magnitude1.nii.gz 6.8 8.8 sub-01_fieldmap
#
# OUTPUT:
#   <output_prefix>_rads.nii.gz  -- fieldmap in rad/s, in FIELDMAP space.
#   It must be registered/resampled to your EPI before `fugue --loadfmap`:
#   fugue does not resample, it pairs voxels by index. See README.

set -e
export FSLOUTPUTTYPE=${FSLOUTPUTTYPE:-NIFTI_GZ}

if [ "$#" -ne 6 ]; then
    echo "Usage: $0 <phase1.nii.gz> <phase2.nii.gz> <magnitude1.nii.gz> <TE1_ms> <TE2_ms> <output_prefix>"
    exit 1
fi

PHASE1=$1
PHASE2=$2
MAG1=$3
TE1=$4
TE2=$5
OUTPREFIX=$6

DELTATE=$(python3 -c "print($TE2 - $TE1)")
echo "Delta TE = ${DELTATE} ms"

echo "=== Brain-extracting magnitude image (tight extraction) ==="
bet "$MAG1" "${OUTPREFIX}_mag_brain" -f 0.6 -R -m

echo "=== Lightly eroding the brain mask (removes noisy edge voxels) ==="
fslmaths "${OUTPREFIX}_mag_brain" -ero "${OUTPREFIX}_mag_brain_ero"
fslmaths "${OUTPREFIX}_mag_brain_ero" -bin "${OUTPREFIX}_mask"

echo "=== Checking phase image value range (expect close to -pi to pi) ==="
RANGE1=$(fslstats "$PHASE1" -R)
RANGE2=$(fslstats "$PHASE2" -R)
echo "phase1 range: $RANGE1"
echo "phase2 range: $RANGE2"
echo "(If these are NOT close to -3.14 to 3.14, your phase images are likely"
echo " in raw scanner units and need rescaling to radians BEFORE running"
echo " this script.)"

PI=3.14159265358979
TWOPI=6.28318530717959

echo "=== Wrapped phase difference: (phase2 - phase1) re-wrapped into [-pi, pi) ==="
fslmaths "$PHASE2" -sub "$PHASE1" "${OUTPREFIX}_dphi_raw" -odt float
# raw difference is in [-2pi, 2pi]; subtract 2pi where >= pi, add 2pi where < -pi
fslmaths "${OUTPREFIX}_dphi_raw" -thr $PI -bin -mul $TWOPI "${OUTPREFIX}_wrap_hi"
fslmaths "${OUTPREFIX}_dphi_raw" -mul -1 -thr $PI -bin -mul $TWOPI "${OUTPREFIX}_wrap_lo"
fslmaths "${OUTPREFIX}_dphi_raw" -sub "${OUTPREFIX}_wrap_hi" -add "${OUTPREFIX}_wrap_lo" \
    "${OUTPREFIX}_dphi_wrapped" -odt float

echo "=== Unwrapping the single difference image with prelude ==="
prelude -a "${OUTPREFIX}_mag_brain_ero" -p "${OUTPREFIX}_dphi_wrapped" \
    -o "${OUTPREFIX}_dphi_unwrapped"

echo "=== Removing any whole-wrap (2*pi*k) offset using the in-brain median ==="
MEDIAN=$(fslstats "${OUTPREFIX}_dphi_unwrapped" -k "${OUTPREFIX}_mask" -P 50)
K=$(python3 -c "print(round($MEDIAN / $TWOPI))")
echo "in-brain median = $MEDIAN rad; removing $K whole wrap(s)"
fslmaths "${OUTPREFIX}_dphi_unwrapped" -sub $(python3 -c "print($K * $TWOPI)") \
    "${OUTPREFIX}_dphi_unwrapped" -odt float

echo "=== Computing fieldmap in rad/s ==="
fslmaths "${OUTPREFIX}_dphi_unwrapped" -mul 1000 -div "$DELTATE" \
    "${OUTPREFIX}_rads" -odt float

MED_HZ=$(python3 -c "print(round($(fslstats "${OUTPREFIX}_rads" -k "${OUTPREFIX}_mask" -P 50) / $TWOPI, 1))")
echo ""
echo "=== Done: ${OUTPREFIX}_rads.nii.gz (in-brain median ${MED_HZ} Hz; expect within a few tens of Hz of 0) ==="
echo "Remember: resample it to your EPI grid before fugue -- see README."
