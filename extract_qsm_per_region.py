import nibabel as nib
import argparse
import numpy as np
import csv
import os
from scipy.ndimage import binary_erosion

parser = argparse.ArgumentParser(description='Extract QSM values per brain region from segmentation data.')

parser.add_argument('--id', type=int, help="ID", required=True)
parser.add_argument('--ses', type=int, help="session", required=True)
parser.add_argument('--qsm_in_T1', type=str, help="Path to the QSM in T1 space NIfTI file", required=True)
parser.add_argument('--segmentation', type=str, help="Path to the segmentation MGZ file", required=True)
parser.add_argument('--qsm_in_mni152', type=str, help="Path to the QSM in MNI152 space NIfTI file", required=True)
parser.add_argument('--lesions_mask', type=str, help="Path to the lesions mask in T1 space NIfTI file", required=False)
parser.add_argument('--sn_mask_left', type=str, help="Path to the left SN mask in MNI space", required=True)
parser.add_argument('--sn_mask_right', type=str, help="Path to the right SN mask in MNI space", required=True)
parser.add_argument('--output_csv', type=str, help="Path to the output CSV file", required=True)

args = parser.parse_args()


## Segmentation from FreeSurfer aseg.mgz

regions_dic = {10: 'Left-Thalamus-Proper',
               11: 'Left-Caudate',
               12: 'Left-Putamen',
               13: 'Left-Pallidum',
               17: 'Left-Hippocampus',
               18: 'Left-Amygdala',
               26: 'Left-Accumbens-area',
               49: 'Right-Thalamus-Proper',
               50: 'Right-Caudate',
               51: 'Right-Putamen',
               52: 'Right-Pallidum',
               53: 'Right-Hippocampus',
               54: 'Right-Amygdala',
               58: 'Right-Accumbens-area'}

seg_img = nib.load(args.segmentation)
seg_data = np.asarray(seg_img.dataobj)

qsm_img = nib.load(args.qsm_in_T1)
qsm_data = qsm_img.get_fdata()

qsm_by_region = {}
for seg_id in regions_dic.keys():
    mask = seg_data == seg_id
    # Apply 2D erosion slice-by-slice to match UKB pipeline (FSL -kernel 2D -ero)
    eroded_mask = np.zeros_like(mask)
    for z in range(mask.shape[2]):
        eroded_mask[:, :, z] = binary_erosion(mask[:, :, z])
    qsm_values = qsm_data[eroded_mask]
    qsm_values = qsm_values[~np.isnan(qsm_values)]
    qsm_by_region[regions_dic[seg_id]] = np.median(qsm_values) if len(qsm_values) > 0 else np.nan


## Substantia nigra regions (left/right, matching UKB pipeline)

sn_mask_left = nib.load(args.sn_mask_left)
sn_left_data = sn_mask_left.get_fdata()

sn_mask_right = nib.load(args.sn_mask_right)
sn_right_data = sn_mask_right.get_fdata()

qsm_in_mni = nib.load(args.qsm_in_mni152)
qsm_mni_data = qsm_in_mni.get_fdata()

# Left SN -- only positive QSM voxels (matching UKB pipeline)
mask_sn_left = sn_left_data > 0
qsm_values_sn_left = qsm_mni_data[mask_sn_left]
qsm_values_sn_left = qsm_values_sn_left[~np.isnan(qsm_values_sn_left)]
qsm_values_sn_left = qsm_values_sn_left[qsm_values_sn_left > 0]
qsm_by_region['SN_L'] = np.median(qsm_values_sn_left) if len(qsm_values_sn_left) > 0 else np.nan

# Right SN -- only positive QSM voxels
mask_sn_right = sn_right_data > 0
qsm_values_sn_right = qsm_mni_data[mask_sn_right]
qsm_values_sn_right = qsm_values_sn_right[~np.isnan(qsm_values_sn_right)]
qsm_values_sn_right = qsm_values_sn_right[qsm_values_sn_right > 0]
qsm_by_region['SN_R'] = np.median(qsm_values_sn_right) if len(qsm_values_sn_right) > 0 else np.nan


## WMH from lesions

if args.lesions_mask and os.path.isfile(args.lesions_mask):
    wmh_mask = nib.load(args.lesions_mask)
    wmh_data = wmh_mask.get_fdata()

    qsm_values_wmh = qsm_data[wmh_data == 1]
    qsm_values_wmh = qsm_values_wmh[~np.isnan(qsm_values_wmh)]
    qsm_by_region['WMH'] = np.median(qsm_values_wmh) if len(qsm_values_wmh) > 0 else np.nan

    ## WM

    left_white_matter = 2
    right_white_matter = 41

    wm_mask_data = np.logical_or(seg_data == left_white_matter, seg_data == right_white_matter).astype(np.uint8)

    qsm_values_in_wm = qsm_data[wm_mask_data == 1]
    qsm_values_in_wm = qsm_values_in_wm[~np.isnan(qsm_values_in_wm)]
    qsm_by_region['WM'] = np.median(qsm_values_in_wm) if len(qsm_values_in_wm) > 0 else np.nan

    ## WM without lesions

    wm_without_lesions_mask = np.logical_and(wm_mask_data == 1, wmh_data == 0).astype(np.uint8)
    qsm_values_in_wm_without_lesions = qsm_data[wm_without_lesions_mask == 1]
    qsm_values_in_wm_without_lesions = qsm_values_in_wm_without_lesions[~np.isnan(qsm_values_in_wm_without_lesions)]
    qsm_by_region['WM_no_lesions'] = np.median(qsm_values_in_wm_without_lesions) if len(qsm_values_in_wm_without_lesions) > 0 else np.nan

    qsm_by_region['Diff-WM'] = qsm_by_region['WM'] - qsm_by_region['WMH']
    qsm_by_region['Diff-WM-no-lesions'] = qsm_by_region['WM_no_lesions'] - qsm_by_region['WMH']


## Add to output.csv

outfile = args.output_csv
header = ["subject", "session"] + list(qsm_by_region.keys())
row = [args.id, args.ses] + list(qsm_by_region.values())

file_exists = os.path.isfile(outfile)

with open(outfile, "a", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    if not file_exists:
        writer.writerow(header)
    writer.writerow(row)
