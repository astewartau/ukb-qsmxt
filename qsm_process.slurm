#!/bin/bash --login
#SBATCH --job-name=qsm-process
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=10:00:00
#SBATCH --qos=normal
#SBATCH --partition=general
#SBATCH --account=a_ai_collab
#SBATCH --output=qsm_process_%A_%a.out
#SBATCH --array=1-3

set -e

start=$(date +%s)

# ---- Configuration ----
CONDA_ENV="${CONDA_ENV:-qsmxt}"
SUBJECT_LIST="${SUBJECT_LIST:-ids_multi_sessions_20219.txt}"
DATA_DIR="${DATA_DIR:-$(dirname "$0")/data}"
SCRATCH_DIR="${SCRATCH_DIR:-/scratch/user/$USER}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# UKB bulk data locations
UKB_SWI_DICOM_DIR="${UKB_SWI_DICOM_DIR:-/QRISdata/Q8577/bulk/20219}"
UKB_FS_DIR="${UKB_FS_DIR:-/QRISdata/Q7990/bulk/20263}"
UKB_WMH_DIR="${UKB_WMH_DIR:-/QRISdata/Q7990/bulk/20253_ASHLEY}"
QSMXT_OUTPUT="${QSMXT_OUTPUT:-/QRISdata/Q8577/QSMxT}"

# ---- Environment setup ----
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"
module load freesurfer
module load fsl
module load julia

# ---- Subject selection ----
mapfile -t repeated_ID < "$SUBJECT_LIST"
ID=${repeated_ID[$SLURM_ARRAY_TASK_ID-1]}

echo "Job $SLURM_ARRAY_TASK_ID finds ID : $ID"

# ============================================================
# PART 1: QSMxT Processing (DICOM → QSM)
# ============================================================

CHEMIN=($(find "${UKB_SWI_DICOM_DIR}"/batch_* -name "*${ID}*.zip"))

echo "Found:"
printf " - %s\n" "${CHEMIN[@]}"

DEST="${SCRATCH_DIR}/QSM_PROCESSING/${ID}"

mkdir -p "$DEST"

for zipfile in "${CHEMIN[@]}"; do
    echo "Copying: $zipfile → $DEST/"
    cp "$zipfile" "$DEST/"

    local_zip="$DEST/$(basename "$zipfile")"
    echo "Unzipping: $local_zip → $DEST/"
    unzip "$local_zip" -d "$DEST"

    echo "Removing local copy: $local_zip"
    rm -v "$local_zip"
done

BIDSFOLDER="${SCRATCH_DIR}/QSM_PROCESSING/bids_${ID}"

dicom-convert "$DEST" "$BIDSFOLDER" --auto_yes
rm -r "$DEST"

# Fix mis-named subjects in BIDS
for wrongsub in "${BIDSFOLDER}"/sub-*; do
    echo "$wrongsub"
    [ "$wrongsub" = "${BIDSFOLDER}/sub-${ID}" ] && continue

    SESSION=$(basename "$(find "$wrongsub" -maxdepth 1 -type d -name 'ses-*')")

    mkdir -p "${BIDSFOLDER}/sub-${ID}/${SESSION}/anat"

    find "$wrongsub/$SESSION/anat" -type f | while read -r f; do
        base=$(basename "$f")
        new_name=$(echo "$base" | sed "s/sub-[a-zA-Z0-9]\+/sub-${ID}/")
        mv "$f" "${BIDSFOLDER}/sub-${ID}/${SESSION}/anat/${new_name}"
    done
    rm -rf "$wrongsub"
done

# Remove incomplete acquisitions (missing CoilString in JSON)
for json in $(grep -rL "CoilString" "${BIDSFOLDER}/sub-${ID}/ses-"*/anat/*.json 2>/dev/null); do
    rm -v "$json" "${json%.json}.nii"
done

# Run QSMxT
qsmxt "$BIDSFOLDER" --do_qsm --do_t2starmap --do_r2starmap --do_swi --auto_yes

# Copy results to output collection
cp -r "${BIDSFOLDER}"/derivatives/qsmxt*/sub* "${QSMXT_OUTPUT}/"
cp -f "${BIDSFOLDER}"/derivatives/qsmxt*/command.txt "${QSMXT_OUTPUT}/sub-${ID}"

for sesdir in "${BIDSFOLDER}/sub-${ID}"/ses-*; do
    ses=$(basename "$sesdir")
    cp -f "$sesdir"/anat/*echo-01_part-mag_MEGRE.nii "${QSMXT_OUTPUT}/sub-${ID}/${ses}/"
done

rm -r "$BIDSFOLDER"

# ============================================================
# PART 2: Region-wise Analysis (FreeSurfer-based)
# ============================================================

CHEMIN_FS=($(find "${UKB_FS_DIR}"/20263_part_*/batch_* -name "*${ID}*.zip"))
CHEMIN_WMH=($(find "${UKB_WMH_DIR}"/batch_* -name "*${ID}*.zip"))

DEST="${SCRATCH_DIR}/REGION_WISE/${ID}"
mkdir -p "$DEST"

for zipfile in "${CHEMIN_FS[@]}"; do
    echo "Processing: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    DEST_FINAL="$DEST/ses-${instance}"
    mkdir -p "$DEST_FINAL"

    echo "Copying: $zipfile → $DEST/"
    cp "$zipfile" "$DEST/"

    local_zip="$DEST/$(basename "$zipfile")"
    echo "Unzipping: $local_zip → $DEST_FINAL/"
    unzip "$local_zip" -d "$DEST_FINAL"

    echo "Removing local copy: $local_zip"
    rm -v "$local_zip"
done

for zipfile in "${CHEMIN_WMH[@]}"; do
    echo "Processing: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    DEST_FINAL="$DEST/ses-${instance}"

    echo "Copying: $zipfile → $DEST/"
    cp "$zipfile" "$DEST/"

    local_zip="$DEST/$(basename "$zipfile")"
    echo "Unzipping: $local_zip → $DEST_FINAL/"
    unzip "$local_zip" -d "$DEST_FINAL"

    echo "Removing local copy: $local_zip"
    rm -v "$local_zip"
done

# ---- Match QSMxT sessions ----
mapfile -t SESSIONS < <(
    find "${QSMXT_OUTPUT}/sub-${ID}/" -maxdepth 1 -type d -name "ses-*" \
    | sed 's#.*/ses-##' \
    | sort
)

i=1
for date in "${SESSIONS[@]}"; do
    echo "Processing session $i with date $date for subject ${ID}"

    QSM_DIR="${QSMXT_OUTPUT}/sub-${ID}/ses-${date}/"
    FS_DIR="$DEST/ses-${i}/FreeSurfer/"
    WM_DIR="$DEST/ses-${i}/T2_FLAIR/"

    # Convert FreeSurfer T1 to NIfTI
    mri_convert "${FS_DIR}/mri/T1.mgz" "${DEST}/ses-${i}/T1.nii.gz"

    SEG="${FS_DIR}/mri/aseg.mgz"
    T1="${DEST}/ses-${i}/T1.nii.gz"
    MAG=("${QSM_DIR}"/*part-mag_MEGRE.nii)
    MAG="${MAG[0]}"
    QSM=("${QSM_DIR}"/anat/*MEGRE_Chimap.nii)
    QSM="${QSM[0]}"

    echo "For $date, session $i, QSM DIR : $QSM_DIR and FS DIR : $FS_DIR"

    # 1) Register magnitude → T1
    "${SCRIPT_DIR}/register_mag_to_t1.sh" "${MAG}" "${T1}" "${DEST}/ses-${i}/mag_to_t1_"

    # 2) QSM → T1 (spline interpolation to match UKB)
    antsApplyTransforms \
        -d 3 \
        -i "${QSM}" \
        -r "${T1}" \
        -t "${DEST}/ses-${i}/mag_to_t1_0GenericAffine.mat" \
        -o "${DEST}/ses-${i}/qsm_in_T1_space.nii.gz" \
        -n BSpline

    # 3) QSM → MNI using UKB nonlinear warp (if available)
    if [ -f "${DEST}/ses-${i}/T1_to_MNI_warp_coef.nii.gz" ]; then
        echo "Using UKB nonlinear warp for MNI registration"
        applywarp --rel \
            -i "${DEST}/ses-${i}/qsm_in_T1_space.nii.gz" \
            -r "${FSLDIR}/data/standard/MNI152_T1_1mm" \
            -w "${DEST}/ses-${i}/T1_to_MNI_warp_coef.nii.gz" \
            -o "${DEST}/ses-${i}/qsm_in_mni152.nii.gz" \
            --interp=spline
    else
        echo "UKB warp not available, using ANTs SyN for MNI registration"
        antsRegistrationSyNQuick.sh -d 3 \
            -f "${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz" \
            -m "${DEST}/ses-${i}/mag_to_t1_Warped.nii.gz" \
            -o "${DEST}/ses-${i}/t1_to_mni_" \
            -t s

        antsApplyTransforms \
            -d 3 \
            -i "${DEST}/ses-${i}/qsm_in_T1_space.nii.gz" \
            -r "${FSLDIR}/data/standard/MNI152_T1_1mm.nii.gz" \
            -t "${DEST}/ses-${i}/t1_to_mni_1Warp.nii.gz" \
            -t "${DEST}/ses-${i}/t1_to_mni_0GenericAffine.mat" \
            -o "${DEST}/ses-${i}/qsm_in_mni152.nii.gz" \
            -n BSpline
    fi

    # Brain mask in MNI space
    fslmaths "${DEST}/ses-${i}/qsm_in_mni152.nii.gz" \
        -mul "${FSLDIR}/data/standard/MNI152_T1_1mm_brain_mask.nii.gz" \
        "${DEST}/ses-${i}/qsm_in_mni152.nii.gz"

    # 4) Register FLAIR lesion mask to T1 space
    if [ -f "${WM_DIR}/T2_FLAIR.nii.gz" ] && [ -f "${WM_DIR}/lesions/final_mask.nii.gz" ]; then
        flirt -in "${WM_DIR}/T2_FLAIR.nii.gz" -ref "${T1}" \
            -out "${DEST}/ses-${i}/T2_to_T1.nii.gz" \
            -omat "${DEST}/ses-${i}/T2_to_T1.mat"

        flirt -in "${WM_DIR}/lesions/final_mask.nii.gz" -ref "${T1}" \
            -applyxfm -init "${DEST}/ses-${i}/T2_to_T1.mat" \
            -out "${DEST}/ses-${i}/lesions_in_T1.nii.gz" \
            -interp nearestneighbour

        LESION_ARG="--lesions_mask ${DEST}/ses-${i}/lesions_in_T1.nii.gz"
    else
        echo "WARNING: FLAIR/lesion data not found for session ${i}, skipping WMH extraction"
        LESION_ARG=""
    fi

    # 5) Extract region-wise QSM values
    python "${SCRIPT_DIR}/extract_qsm_per_region.py" \
        --id "${ID}" \
        --ses "${i}" \
        --qsm_in_T1 "${DEST}/ses-${i}/qsm_in_T1_space.nii.gz" \
        --segmentation "${SEG}" \
        --qsm_in_mni152 "${DEST}/ses-${i}/qsm_in_mni152.nii.gz" \
        --sn_mask_left "${DATA_DIR}/SN_mask_Left.nii.gz" \
        --sn_mask_right "${DATA_DIR}/SN_mask_Right.nii.gz" \
        ${LESION_ARG} \
        --output_csv "${DEST}/region_wise_sub-${ID}.csv"
    ((i++))
done

rm -r "${DEST}"

end=$(date +%s)
runtime=$((end-start))
echo "Runtime : $runtime seconds"
