
#!/bin/bash 

set -e

module load fsl

if [ $# -lt 2 ]; then
    echo "Usage: $0 <dir> <qsmxt.nii>"
    exit 1
fi

DIR="$1"
QSMxT="$2"
shift 2


flirt \
    -in "$QSMxT" \
    -ref "$DIR"/T1.nii.gz \
    -applyxfm -init "$DIR"/SWI_to_T1.mat \
    -out "$DIR"/QSMxT_to_T1.nii.gz \
    -interp spline


fslmaths \
    "$DIR"/QSMxT_to_T1.nii.gz \
    -mul "$DIR"/T1_brain_mask.nii.gz \
    "$DIR"/QSMxT_to_T1.nii.gz

invwarp \
    --ref="$DIR"/T1.nii.gz \
    -w "$DIR"/T1_to_MNI_warp_coef.nii.gz \
    -o "$DIR"/T1_to_MNI_warp_coef_inv.nii.gz

fslmaths "$DIR"/T1.nii.gz \
    -div "$DIR"/T1_brain_bias.nii.gz \
    "$DIR"/T1_unbiased.nii.gz

make_bianca_mask \
    "$DIR"/T1_unbiased.nii.gz \
    "$DIR"/T1_brain_pve_0.nii.gz \
    "$DIR"/T1_to_MNI_warp_coef_inv.nii.gz 

fslmaths "$DIR"/T1_unbiased_ventmask.nii.gz \
    -kernel sphere 1 -ero -bin \
    -mul "$DIR"/QSMxT_to_T1.nii.gz \
    "$DIR"/ROI_QSMxT_CSF.nii.gz

CSF_VALUE=$(fslstats "$DIR"/ROI_QSMxT_CSF.nii.gz -P 50)
echo $CSF_VALUE > "$DIR"/QSMxT_CSF.txt


# source $BB_BIN_DIR/bb_python/bb_python_asl_ukbb/bin/activate
# ${QSMDir}/Mix_Mod_IDPs_CSF.py \
#    -id $1/SWI/QSM \
#    -codedir ${QSMDir}/Python_Scripts
# deactivate


CSF_VALUE=$(cat "$DIR"/QSMxT_CSF.txt)

fslmaths "$QSMxT" \
    -sub $CSF_VALUE \
    "$DIR"/QSMxT_CSFref.nii.gz

fslmaths "$QSMxT" -abs -bin "$DIR"/QSMxT_mask_tmp.nii.gz

fslmaths "$DIR"/QSMxT_CSFref.nii.gz \
    -mul "$DIR"/QSMxT_mask_tmp.nii.gz \
    "$DIR"/QSMxT_CSFref.nii.gz



