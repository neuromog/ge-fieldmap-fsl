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
# what many GE scanners produce. This script implements the correct,
# FSL-documented fix: unwrap EACH phase image separately with `prelude`
# (referenced to the same magnitude image), THEN subtract the two already-
# unwrapped images. Subtracting the raw wrapped phase images directly
# (a common mistake) produces incorrect values at wrap-around boundaries.
#
# REQUIREMENTS: FSL (bet, prelude, fslmaths) already installed and on PATH.
# No other dependencies -- deliberately avoids extra packages that can
# introduce their own installation friction (e.g. shimming-toolbox).
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
#   <output_prefix>_rads.nii.gz  -- fieldmap in rad/s, ready for:
#       fugue --in=<epi> --dwell=<EffectiveEchoSpacing> \
#             --loadfmap=<output_prefix>_rads.nii.gz --unwarpdir=<dir> -u <out>

set -e

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
bet "$MAG1" "${OUTPREFIX}_mag_brain.nii.gz" -f 0.6 -R -m

echo "=== Lightly eroding the brain mask (removes noisy edge voxels) ==="
fslmaths "${OUTPREFIX}_mag_brain.nii.gz" -ero "${OUTPREFIX}_mag_brain_ero.nii.gz"

echo "=== Checking phase image value range (expect close to -pi to pi) ==="
RANGE1=$(fslstats "$PHASE1" -R)
RANGE2=$(fslstats "$PHASE2" -R)
echo "phase1 range: $RANGE1"
echo "phase2 range: $RANGE2"
echo "(If these are NOT close to -3.14 to 3.14, your phase images are likely"
echo " in raw scanner units and need rescaling to radians BEFORE running"
echo " this script -- see README for the rescaling formula.)"

echo "=== Unwrapping each phase image separately (this is the key fix) ==="
prelude -a "${OUTPREFIX}_mag_brain_ero.nii.gz" -p "$PHASE1" -o "${OUTPREFIX}_phase1_unwrapped.nii.gz"
prelude -a "${OUTPREFIX}_mag_brain_ero.nii.gz" -p "$PHASE2" -o "${OUTPREFIX}_phase2_unwrapped.nii.gz"

echo "=== Computing fieldmap in rad/s ==="
fslmaths "${OUTPREFIX}_phase2_unwrapped.nii.gz" -sub "${OUTPREFIX}_phase1_unwrapped.nii.gz" \
    -mul 1000 -div "$DELTATE" "${OUTPREFIX}_rads.nii.gz" -odt float

echo ""
echo "=== Done: ${OUTPREFIX}_rads.nii.gz is ready for use with FUGUE ==="
