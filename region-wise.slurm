#!/bin/bash --login
#SBATCH --job-name=region-wise
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=10:00:00
#SBATCH --qos=normal
#SBATCH --partition=general
#SBATCH --account=a_ai_collab
#SBATCH --output=test_array_%A_%a.out
#SBATCH --array=1-39


conda activate qsmxt
module load freesurfer
module load fsl

export PATH=/home/uqclauve/miniforge3/envs/qsmxt/bin/:$PATH


mapfile -t repeated_ID < ids_multi_sessions_20219.txt
ID=${repeated_ID[$SLURM_ARRAY_TASK_ID-1]}

echo "Job $SLURM_ARRAY_TASK_ID finds ID : $ID"

CHEMIN_FAST=($(find /QRISdata/Q7990/bulk/20263/20263_part_*/batch_* -name "*${ID}*.zip"))

CHEMIN_WMH=($(find /QRISdata/Q7990/bulk/20253_ASHLEY/batch_* -name "*${ID}*.zip"))

DEST="/home/uqclauve/data/REGION_WISE/${ID}"

mkdir -p "$DEST"

for zipfile in "${CHEMIN_FAST[@]}"; do

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


mapfile -t SESSIONS < <(
    find "/QRISdata/Q8577/QSMxT/sub-${ID}/" -maxdepth 1 -type d -name "ses-*" \
    | sed 's#.*/ses-##' \
    | sort
)

i=1
for date in "${SESSIONS[@]}"; do

    QSM_DIR="/QRISdata/Q8577/QSMxT/sub-${ID}/ses-${date}/"
    FS_DIR="/home/uqclauve/data/REGION_WISE/${ID}/ses-${i}/FreeSurfer/"
    WM_DIR="/home/uqclauve/data/REGION_WISE/${ID}/ses-${i}/T2_FLAIR/"

    mri_convert "${FS_DIR}/mri/T1.mgz" "${DEST}/ses-${i}/T1.nii.gz"

	SEG="${FS_DIR}/mri/aseg.mgz"


	T1="${DEST}/ses-${i}/T1.nii.gz"
	MAG=("${QSM_DIR}"/*part-mag_MEGRE.nii)
    MAG="${MAG[0]}"

	QSM=("${QSM_DIR}"/anat/*MEGRE_Chimap.nii)
    QSM="${QSM[0]}"

	MNI152="/home/uqclauve/data/template_mni152.nii"
	SNc_mask="/home/uqclauve/data/SNc_mask.nii.gz"
	SNr_mask="/home/uqclauve/data/SNr_mask.nii.gz"

    echo "For $date, session $i, QSM DIR : $QSM_DIR and FS DIR : $FS_DIR"

    antsRegistration \
        -d 3 \
        -r ["${MAG}","${T1}",1] \
        -m mattes["${MAG}","${T1}",1,32,regular,0.25] \
        -t rigid[0.1] \
        -c 1000x500x250 \
        -s 4x2x1vox \
        -f 8x4x2 \
        -o ["${DEST}/ses-${i}/mag_to_t1_","${DEST}/ses-${i}/mag_in_t1_space.nii.gz"]

    # 2) QSM → T1
    antsApplyTransforms \
        -d 3 \
        -i "${QSM}" \
        -r "${T1}" \
        -t ["${DEST}/ses-${i}/mag_to_t1_0GenericAffine.mat",1] \
        -o "${DEST}/ses-${i}/qsm_in_T1_space.nii.gz" \
        -n Linear

    # 3) MAG → MNI
    antsRegistrationSyNQuick.sh -d 3 \
        -f "${MNI152}" \
        -m "${MAG}" \
        -o "${DEST}/ses-${i}/mag_to_mni_"

    # 4) QSM → MNI
    antsApplyTransforms \
        -d 3 \
        -i "${QSM}" \
        -r "${MNI152}" \
        -t "${DEST}/ses-${i}/mag_to_mni_0GenericAffine.mat" \
        -o "${DEST}/ses-${i}/qsm_from_mag_in_mni152.nii.gz" \
        -n Linear


    flirt -in "${WM_DIR}"/T2_FLAIR.nii.gz -ref ${T1} -out "${DEST}/ses-${i}/T2_to_T1.nii.gz" -omat "${DEST}/ses-${i}/T2_to_T1.mat"

    flirt -in "${WM_DIR}"/lesions/final_mask.nii.gz -ref ${T1} -applyxfm -init "${DEST}/ses-${i}/T2_to_T1.mat" -out "${DEST}/ses-${i}/lesions_in_T1.nii.gz" -interp nearestneighbour

    python extract_qsm_per_region.py \
        --id ${ID} \
        --ses ${i} \
        --qsm_in_T1 "${DEST}/ses-${i}/qsm_in_T1_space.nii.gz" \
        --segmentation "${SEG}" \
        --qsm_in_mni152 "${DEST}/ses-${i}/qsm_from_mag_in_mni152.nii.gz" \
        --lesions_mask "${DEST}/ses-${i}/lesions_in_T1.nii.gz" \
        --output_csv "/home/uqclauve/data/REGION_WISE/output.csv"

    ((i++))
done
 
rm -r ${DEST}



