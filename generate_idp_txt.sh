#!/bin/bash 

set -e

module load fsl

if [ $# -lt 3 ]; then
    echo "Usage: $0 <dir> <instance> <prefix>"
    exit 1
fi

DEST="$1"
instance="$2"
prefix="$3"

shift 3

flirt -in "$DEST/ses-${instance}/${prefix}_CSFref.nii.gz" \
        -ref "$DEST/ses-${instance}/T1.nii.gz" \
        -applyxfm -init "$DEST/ses-${instance}/SWI_to_T1.mat" \
        -out "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz" \
        -interp spline


fslmaths "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz" -mul "$DEST/ses-${instance}/T1_brain_mask.nii.gz" "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz"


applywarp --rel -i "$DEST/ses-${instance}/${prefix}_CSFref.nii.gz" -r /home/uqclauve/data/MNI152_T1_1mm.nii.gz -w "$DEST/ses-${instance}/T1_to_MNI_warp_coef.nii.gz" -o "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" --premat="$DEST/ses-${instance}/SWI_to_T1.mat" --interp=spline



fslmaths "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz" -mul /home/uqclauve/data/MNI152_T1_1mm_brain_mask "$DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz"

while read STRUCT THR1 THR2 ; do 
    fslmaths "$DEST/ses-${instance}/T1_first_all_fast_firstseg.nii.gz" -thr ${THR1} -uthr ${THR2} -bin -kernel 2D -ero -bin -mul "$DEST/ses-${instance}/${prefix}_CSFref_to_T1.nii.gz" "$DEST/ses-${instance}/ROI_${prefix}_${STRUCT}"
done < /home/uqclauve/data/first_data.txt

fslmaths \
    $DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz \
    -mul /home/uqclauve/data/SN_mask_Left.nii.gz \
    -thr 0 -bin \
    $DEST/ses-${instance}/SN_${prefix}_positive_mask_Left.nii.gz

fslmaths \
    $DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz \
    -mul /home/uqclauve/data/SN_mask_Right.nii.gz \
    -thr 0 -bin \
    $DEST/ses-${instance}/SN_${prefix}_positive_mask_Right.nii.gz

fslmaths \
    $DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz \
    -mul $DEST/ses-${instance}/SN_${prefix}_positive_mask_Right.nii.gz \
    $DEST/ses-${instance}/${prefix}_SN_R.nii.gz

fslmaths \
    $DEST/ses-${instance}/${prefix}_CSFref_to_MNI.nii.gz \
    -mul $DEST/ses-${instance}/SN_${prefix}_positive_mask_Left.nii.gz \
    $DEST/ses-${instance}/${prefix}_SN_L.nii.gz

vals=""
for STRUCT in `cat /home/uqclauve/data/first_data.txt | awk '{print $1}'` ; do
    vals="${vals} `fslstats $DEST/ses-${instance}/ROI_${prefix}_${STRUCT}.nii.gz -P 50`"
done

val15=`fslstats $DEST/ses-${instance}/${prefix}_SN_L.nii.gz -P 50` 
val16=`fslstats $DEST/ses-${instance}/${prefix}_SN_R.nii.gz -P 50` 

echo "${vals} ${val15} ${val16}" > $DEST/ses-${instance}/${prefix}_CSFref_IDPs.txt

echo -e "\\n"
echo "Extration finished for ${prefix} session ${instance}."
echo -e "\\n"