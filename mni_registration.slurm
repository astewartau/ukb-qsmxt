#!/bin/bash --login
#SBATCH --job-name=mni-reg
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=10:00:00
#SBATCH --qos=normal
#SBATCH --partition=general
#SBATCH --account=a_ai_collab
#SBATCH --output=error_array_%A_%a.out
#SBATCH --array=1-999%100

set -e

# ---- Configuration ----
# Override these via environment variables or edit here
CONDA_ENV="${CONDA_ENV:-qsmxt}"
SUBJECT_LIST="${SUBJECT_LIST:-ids_multi_sessions_20219.txt}"
DATA_DIR="${DATA_DIR:-$(dirname "$0")/data}"
SCRATCH_DIR="${SCRATCH_DIR:-/scratch/user/$USER}"
QSMXT_OUTPUT_DIR="${QSMXT_OUTPUT_DIR:-/QRISdata/Q9014/QSMxT}"

# UKB bulk data locations
UKB_T1_DIR="${UKB_T1_DIR:-/QRISdata/Q7990/bulk/20252_ASHLEY}"
UKB_QSM_DIR="${UKB_QSM_DIR:-/QRISdata/Q8577/bulk/26301}"
UKB_SWI_DIR="${UKB_SWI_DIR:-/QRISdata/Q7990/bulk/20251}"

# ---- Environment setup ----
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"
module load ants
module load freesurfer
module load fsl

# ---- Subject selection ----
mapfile -t repeated_ID < "$SUBJECT_LIST"
ID=${repeated_ID[$SLURM_ARRAY_TASK_ID-1]}

echo "Job $SLURM_ARRAY_TASK_ID finds ID : $ID"

DEST="${SCRATCH_DIR}/UKB_PROCESSING/${ID}"

# ---- Extract T1 data (field 20252) ----
CHEMIN_T1=($(find "${UKB_T1_DIR}"/batch_* -name "*${ID}*.zip"))
echo "For T1 found:"
printf " - %s\n" "${CHEMIN_T1[@]}"

if [[ "${#CHEMIN_T1[@]}" -lt 2 ]]; then
    echo "${ID}" >> "${SCRATCH_DIR}/missing_20252_ids.txt"
    echo "[ERROR] ${ID}: only ${#CHEMIN_T1[@]} file(s) found for T1 — stopping job."
    exit 1
fi

mkdir -p "$DEST/ses-1/" "$DEST/ses-2/"

for zipfile in "${CHEMIN_T1[@]}"; do
    echo "Extracting T1 from: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    local_zip="${SCRATCH_DIR}/$(basename "$zipfile")"
    rsync -ah --progress "$zipfile" "$local_zip"
    unzip -j "$local_zip" \
        "*/T1.nii.gz" \
        "*/T1_first_all_fast_firstseg.nii.gz" \
        "*/T1_brain_mask.nii.gz" \
        "*/T1_to_MNI_warp_coef.nii.gz" \
        "*/T1_brain_bias.nii.gz" \
        "*/T1_brain_pve_0.nii.gz" \
        "*/T1_unbiased_brain.nii.gz" \
        -d "$DEST/ses-${instance}/"
    rm "$local_zip"
done

# ---- Extract UKB QSM (field 26301) ----
CHEMIN_QSM=($(find "${UKB_QSM_DIR}"/batch_* -name "*${ID}*.zip"))
echo "For QSM Found:"
printf " - %s\n" "${CHEMIN_QSM[@]}"

for zipfile in "${CHEMIN_QSM[@]}"; do
    echo "Extracting QSM from: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    local_zip="${SCRATCH_DIR}/$(basename "$zipfile")"
    rsync -ah --progress "$zipfile" "$local_zip"
    unzip -j "$local_zip" "*/QSM_CSFref.nii.gz" -d "$DEST/ses-${instance}/"
    mv "$DEST/ses-${instance}/QSM_CSFref.nii.gz" "$DEST/ses-${instance}/UKBQSM_CSFref.nii.gz"
    rm "$local_zip"
done

# ---- Extract SWI registration matrices (field 20251) ----
CHEMIN_SWI=($(find "${UKB_SWI_DIR}"/batch_* -name "*${ID}*.zip"))

echo "For SWI Found:"
printf " - %s\n" "${CHEMIN_SWI[@]}"

for zipfile in "${CHEMIN_SWI[@]}"; do
    echo "Extracting SWI from: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    local_zip="${SCRATCH_DIR}/$(basename "$zipfile")"
    rsync -ah --progress "$zipfile" "$local_zip"
    unzip -j "$local_zip" "*/SWI_to_T1.mat" -d "$DEST/ses-${instance}/"
    rm "$local_zip"
done

# ---- Match QSMxT sessions to UKB sessions ----
mapfile -t SESSIONS < <(
    find "${QSMXT_OUTPUT_DIR}/sub-${ID}/" -maxdepth 1 -type d -name "ses-*" \
    | sed 's#.*/ses-##' \
    | sort
)

# ---- Process IDPs for each session ----
i=1
for date in "${SESSIONS[@]}"; do
    echo ""
    echo "Processing session ${i} (date: ${date})..."

    QSMxT=$(ls "${QSMXT_OUTPUT_DIR}/sub-${ID}/ses-${date}/anat/"*MEGRE_Chimap.nii)
    OUTPUT_DIR="${QSMXT_OUTPUT_DIR}/sub-${ID}/ses-${date}"

    ## UKB QSM → MNI
    applywarp --rel \
        -i "$DEST/ses-${i}/UKBQSM_CSFref.nii.gz" \
        -r "$DATA_DIR/MNI152_T1_1mm.nii.gz" \
        -w "$DEST/ses-${i}/T1_to_MNI_warp_coef.nii.gz" \
        -o "${OUTPUT_DIR}/UKBQSM_CSFref_to_MNI.nii.gz" \
        --premat="$DEST/ses-${i}/SWI_to_T1.mat" \
        --interp=spline

    if [ ! -f "${OUTPUT_DIR}/UKBQSM_CSFref_to_MNI.nii.gz" ]; then
        echo "ERROR: applywarp failed for UKB QSM, subject ${ID} session ${i}"
        exit 1
    fi

    ## QSMxT CSF referencing
    "$(dirname "$0")/generate_qsmxt_csfref.sh" "${DEST}/ses-${i}/" "${QSMxT}"

    cp "$DEST/ses-${i}/QSMxT_CSF.txt" "${OUTPUT_DIR}/"
    cp "$DEST/ses-${i}/QSMxT_CSFref.nii.gz" "${OUTPUT_DIR}/"

    ## QSMxT → MNI
    applywarp --rel \
        -i "$DEST/ses-${i}/QSMxT_CSFref.nii.gz" \
        -r "$DATA_DIR/MNI152_T1_1mm.nii.gz" \
        -w "$DEST/ses-${i}/T1_to_MNI_warp_coef.nii.gz" \
        -o "${OUTPUT_DIR}/QSMxT_CSFref_to_MNI.nii.gz" \
        --premat="$DEST/ses-${i}/SWI_to_T1.mat" \
        --interp=spline

    if [ ! -f "${OUTPUT_DIR}/QSMxT_CSFref_to_MNI.nii.gz" ]; then
        echo "ERROR: applywarp failed for QSMxT, subject ${ID} session ${i}"
        exit 1
    fi

    echo "Done with session ${i}"
    ((i++))
done

rm -r "${DEST}"
