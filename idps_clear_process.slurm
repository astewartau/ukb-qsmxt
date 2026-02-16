#!/bin/bash --login
#SBATCH --job-name=first-two
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

export HOME=/home/uqclauve

conda activate qsmxt
module load ants
module load freesurfer
module load fsl

mapfile -t repeated_ID < missing_subjects.txt 
ID=${repeated_ID[$SLURM_ARRAY_TASK_ID-1]}

echo "Job $SLURM_ARRAY_TASK_ID finds ID : $ID"

DEST="/home/uqclauve/data/UKB_PROCESSING/${ID}"



## FIND T1 & FIRST/FAST 

CHEMIN_T1=($(find /QRISdata/Q7990/bulk/20252_ASHLEY/batch_* -name "*${ID}*.zip"))
echo "For T1 found:"
printf " - %s\n" "${CHEMIN_T1[@]}"

# if [[ "${#CHEMIN_T1[@]}" -lt 2 ]]; then
#     echo "${ID}" >> "/home/uqclauve/data/missing_20252_ids.txt"
#     echo "[ERROR] ${ID}: only 1 file(s) found for T1 — stopping job."
#     exit 1
# fi


mkdir -p "$DEST"
mkdir -p "$DEST/ses-1/"
mkdir -p "$DEST/ses-2/"


for zipfile in "${CHEMIN_T1[@]}"; do
    echo "Extracting T1 from: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    local_zip="/scratch/user/uqclauve/$(basename "$zipfile")"
    rsync -ah --progress "$zipfile" "$local_zip"
    unzip -j "$local_zip" "*/T1.nii.gz" "*/T1_first_all_fast_firstseg.nii.gz" "*/T1_brain_mask.nii.gz" "*/T1_to_MNI_warp_coef.nii.gz" "*/T1_brain_bias.nii.gz" "*/T1_brain_pve_0.nii.gz" "*/T1_unbiased_brain.nii.gz" -d "$DEST/ses-${instance}/"
    rm "$local_zip"
done



## UKB PROCESSED QSM

CHEMIN_QSM=($(find /QRISdata/Q8577/bulk/26301/batch_* -name "*${ID}*.zip"))
echo "For QSM Found:"
printf " - %s\n" "${CHEMIN_QSM[@]}"

for zipfile in "${CHEMIN_QSM[@]}"; do
    echo "Extracting QSM from: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    local_zip="/scratch/user/uqclauve/$(basename "$zipfile")"
    rsync -ah --progress "$zipfile" "$local_zip"
    unzip -j "$local_zip" "*/QSM_CSFref.nii.gz" -d "$DEST/ses-${instance}/"
    mv "$DEST/ses-${instance}/QSM_CSFref.nii.gz" "$DEST/ses-${instance}/UKBQSM_CSFref.nii.gz"
    rm "$local_zip"
done


## TRANSFORMATION MATRICE

CHEMIN_SWI=($(find /QRISdata/Q7990/bulk/20251/batch_* -name "*${ID}*.zip"))

echo "For SWI Found:"
printf " - %s\n" "${CHEMIN_SWI[@]}"

for zipfile in "${CHEMIN_SWI[@]}"; do
    echo "Extracting SWI from: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    local_zip="/scratch/user/uqclauve/$(basename "$zipfile")"
    rsync -ah --progress "$zipfile" "$local_zip"
    unzip -j "$local_zip" "*/SWI_to_T1.mat" -d "$DEST/ses-${instance}/"
    rm "$local_zip"
done


## LESIONS FILES

CHEMIN_WMH=($(find /QRISdata/Q7990/bulk/20253_ASHLEY/batch_* -name "*${ID}*.zip"))

for zipfile in "${CHEMIN_WMH[@]}"; do

    echo "Processing: $zipfile"
    instance=$(basename "$zipfile" | cut -d'_' -f3)
    instance=$((instance - 1))
    echo " → Session : $instance"

    DEST_FINAL="$DEST/ses-${instance}/T2_FLAIR/"
    mkdir -p "$DEST_FINAL"
    local_zip="$DEST/ses-${instance}/$(basename "$zipfile")"
    rsync -ah --progress "$zipfile" "$local_zip"
    unzip -j "$local_zip" "*/T2_FLAIR.nii.gz" "*/lesions/final_mask.nii.gz" -d "$DEST_FINAL"
    rm "$local_zip"
done



mapfile -t SESSIONS < <(
    find "/QRISdata/Q9014/QSMxT/sub-${ID}/" -maxdepth 1 -type d -name "ses-*" \
    | sed 's#.*/ses-##' \
    | sort
)

## EXTRACTION OF IDPs

i=1
for date in "${SESSIONS[@]}"; do

    QSMxT=$(ls /QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}/anat/*MEGRE_Chimap.nii)

    if [ -z $(find "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}" -type f -name "QSMxT_CSFref_IDPs.txt") ]; then
        continue
    fi

    /home/uqclauve/data/generate_qsmxt_csfref.sh "${DEST}/ses-${i}/" "${QSMxT}"
    /home/uqclauve/data/generate_idp_txt.sh "${DEST}" $i "QSMxT"
    /home/uqclauve/data/generate_idp_txt.sh "${DEST}" $i "UKBQSM"
    

    cp "$DEST/ses-${i}/UKB_CSFref_to_T1.nii.gz" "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}/"
    cp "$DEST/ses-${i}/QSMxT_CSFref_to_T1.nii.gz" "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}/" 
    cp "$DEST/ses-${i}/UKB_CSFref_to_MNI.nii.gz" "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}/"
    cp "$DEST/ses-${i}/QSMxT_CSFref_to_MNI.nii.gz" "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}/"
    cp "$DEST/ses-${i}/QSMxT_CSF.txt" "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}/"
    #cp "$DEST/ses-${i}/QSMxT_CSFref.nii.gz" "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}/"

    cp "${DEST}/ses-${i}/UKBQSM_CSFref_IDPs.txt" "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}"
    cp "${DEST}/ses-${i}/QSMxT_CSFref_IDPs.txt" "/QRISdata/Q9014/QSMxT/sub-${ID}/ses-${date}"
    
    ((i++))
done

rm -r ${DEST}
