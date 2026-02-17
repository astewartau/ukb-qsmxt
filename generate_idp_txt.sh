#!/bin/bash

set -e

module load fsl

if [ $# -lt 3 ]; then
    echo "Usage: $0 <dir> <instance> <prefix> [--data-dir <path>]"
    echo ""
    echo "  dir        Subject processing directory"
    echo "  instance   Session instance number"
    echo "  prefix     QSM prefix (e.g. UKBQSM or QSMxT)"
    echo "  --data-dir Path to atlas/mask data directory (default: ./data)"
    exit 1
fi

DEST="$1"
instance="$2"
prefix="$3"
shift 3

# Default data directory (contains first_data.txt, SN masks, MNI template/mask)
DATA_DIR="${DATA_DIR:-$(dirname "$0")/data}"

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --data-dir)
            DATA_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Verify required data files exist
for f in "$DATA_DIR/first_data.txt" "$DATA_DIR/SN_mask_Left.nii.gz" "$DATA_DIR/SN_mask_Right.nii.gz" "$DATA_DIR/MNI152_T1_1mm.nii.gz" "$DATA_DIR/MNI152_T1_1mm_brain_mask.nii.gz"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required data file not found: $f"
        echo "Set --data-dir or DATA_DIR to the directory containing atlas files."
        exit 1
    fi
done

# QSM to T1 registration (matches UKB: FLIRT with SWI_to_T1.mat, spline interpolation)
flirt -in "$DEST/ses-${instance}/${prefix}_CSFref.nii.gz" \
        -ref "$DEST/ses-${instance}/T1.nii.gz" \
        -applyxfm -init "$DEST/ses-${instance}/SWI_to_T1.mat" \
        -out "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz" \
        -interp spline

# Brain mask in T1 space
fslmaths "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz" -mul "$DEST/ses-${instance}/T1_brain_mask.nii.gz" "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz"

# QSM to MNI registration (nonlinear warp via applywarp, spline interpolation)
applywarp --rel -i "$DEST/ses-${instance}/${prefix}_CSFref.nii.gz" \
    -r "$DATA_DIR/MNI152_T1_1mm.nii.gz" \
    -w "$DEST/ses-${instance}/T1_to_MNI_warp_coef.nii.gz" \
    -o "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" \
    --premat="$DEST/ses-${instance}/SWI_to_T1.mat" \
    --interp=spline

# Verify applywarp output
if [ ! -f "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" ] || [ "$(fslstats "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" -V | awk '{print $1}')" -eq 0 ]; then
    echo "ERROR: applywarp failed for ${prefix} session ${instance}"
    exit 1
fi

# Brain mask in MNI space
fslmaths "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" -mul "$DATA_DIR/MNI152_T1_1mm_brain_mask.nii.gz" "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz"

# Subcortical ROI extraction using FIRST segmentation (matches UKB: threshold, 2D erosion, median)
while read STRUCT THR1 THR2 ; do
    fslmaths "$DEST/ses-${instance}/T1_first_all_fast_firstseg.nii.gz" -thr ${THR1} -uthr ${THR2} -bin -kernel 2D -ero -bin -mul "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz" "$DEST/ses-${instance}/ROI_${prefix}_${STRUCT}"
done < "$DATA_DIR/regions_first.txt"

# Subcortical ROI extraction using FAST segmentation (matches UKB: threshold, 2D erosion, median)
while read STRUCT THR1 THR2 ; do
    fslmaths "$DEST/ses-${instance}/T1_brain_seg.nii.gz" -thr ${THR1} -uthr ${THR2} -bin -kernel 2D -ero -bin -mul "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz" "$DEST/ses-${instance}/ROI_${prefix}_${STRUCT}"
done < "$DATA_DIR/regions_fast.txt"

# Subcortical ROI extraction using FreeSurfer segmentation 
while read STRUCT THR1 THR2 ; do
    fslmaths "$DEST/ses-${instance}/aseg.nii.gz" -thr ${THR1} -uthr ${THR2} -bin -kernel 2D -ero -bin -mul "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz" "$DEST/ses-${instance}/ROI_${prefix}_${STRUCT}"
done < "$DATA_DIR/regions_free_surfer.txt"



# SN positive-value masks (matches UKB: multiply QSM by SN mask, threshold > 0, binarize)
fslmaths \
    "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" \
    -mul "$DATA_DIR/SN_mask_Left.nii.gz" \
    -thr 0 -bin \
    "$DEST/ses-${instance}/SN_${prefix}_positive_mask_Left.nii.gz"

fslmaths \
    "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" \
    -mul "$DATA_DIR/SN_mask_Right.nii.gz" \
    -thr 0 -bin \
    "$DEST/ses-${instance}/SN_${prefix}_positive_mask_Right.nii.gz"

# Apply SN masks to QSM
fslmaths \
    "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" \
    -mul "$DEST/ses-${instance}/SN_${prefix}_positive_mask_Right.nii.gz" \
    "$DEST/ses-${instance}/${prefix}_SN_R.nii.gz"

fslmaths \
    "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" \
    -mul "$DEST/ses-${instance}/SN_${prefix}_positive_mask_Left.nii.gz" \
    "$DEST/ses-${instance}/${prefix}_SN_L.nii.gz"


# Extract median QSM per subcortical ROI
vals_first=""
for STRUCT in $(awk '{print $1}' "$DATA_DIR/regions_first.txt") ; do
    vals_first="${vals} $(fslstats "$DEST/ses-${instance}/ROI_${prefix}_${STRUCT}.nii.gz" -P 50)"
done

vals_fast=""
for STRUCT in $(awk '{print $1}' "$DATA_DIR/regions_fast.txt") ; do
    vals_fast="${vals_fast} $(fslstats "$DEST/ses-${instance}/ROI_${prefix}_${STRUCT}.nii.gz" -P 50)"
done

vals_freesurfer=""
for STRUCT in $(awk '{print $1}' "$DATA_DIR/regions_free_surfer.txt") ; do
    vals_freesurfer="${vals_fast} $(fslstats "$DEST/ses-${instance}/ROI_${prefix}_${STRUCT}.nii.gz" -P 50)"
done

# Extract median QSM from SN
val15=$(fslstats "$DEST/ses-${instance}/${prefix}_SN_L.nii.gz" -P 50)
val16=$(fslstats "$DEST/ses-${instance}/${prefix}_SN_R.nii.gz" -P 50)

echo "${vals_first} ${vals_fast} ${vals_freesurfer} ${val15} ${val16}" > "$DEST/ses-${instance}/${prefix}_CSFref_IDPs.txt"

echo ""
echo "Extraction finished for ${prefix} session ${instance}."
echo ""
