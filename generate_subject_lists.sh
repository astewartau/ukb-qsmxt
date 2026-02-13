#!/bin/bash
#
# Generate subject lists by cross-referencing UK Biobank bulk data fields.
#
# Extracts unique subject EIDs from zip filenames across all relevant fields
# and computes intersections to identify subjects with complete data.
#
# Usage:
#   ./generate_subject_lists.sh [--output-dir <path>]
#
# Environment variables (with defaults):
#   UKB_SWI_DICOM_DIR   /QRISdata/Q8577/bulk/20219
#   UKB_T1_DIR          /QRISdata/Q7990/bulk/20252 + 20252_ASHLEY
#   UKB_T1_NIFTI_DIR    /QRISdata/Q7990/bulk/20253 + 20253_ASHLEY
#   UKB_FS_DIR          /QRISdata/Q7990/bulk/20263
#   UKB_SWI_REG_DIR     /QRISdata/Q7990/bulk/20251
#   UKB_QSM_DIR         /QRISdata/Q8577/bulk/26301
#   QSMXT_OUTPUT_DIR    /QRISdata/Q9014/QSMxT

set -e

# ---- Configuration ----
OUTPUT_DIR="$(dirname "$0")/subject_lists"

UKB_SWI_DICOM_DIR="${UKB_SWI_DICOM_DIR:-/QRISdata/Q8577/bulk/20219}"
UKB_T1_BASE="${UKB_T1_BASE:-/QRISdata/Q7990/bulk}"
UKB_FS_DIR="${UKB_FS_DIR:-/QRISdata/Q7990/bulk/20263}"
UKB_SWI_REG_DIR="${UKB_SWI_REG_DIR:-/QRISdata/Q7990/bulk/20251}"
UKB_QSM_DIR="${UKB_QSM_DIR:-/QRISdata/Q8577/bulk/26301}"
QSMXT_OUTPUT_DIR="${QSMXT_OUTPUT_DIR:-/QRISdata/Q9014/QSMxT}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

mkdir -p "$OUTPUT_DIR"

echo "========================================"
echo "UKB-QSMxT Subject List Generator"
echo "========================================"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Helper: extract unique subject EIDs from zip filenames in batch directories
# Uses find instead of ls glob to handle large directories on autofs
extract_eids() {
    for d in "$@"; do
        find "$d" -maxdepth 2 -name "*.zip" -printf '%f\n' 2>/dev/null
    done | cut -d_ -f1 | sort -u
}

# ---- Extract per-field subject lists ----

echo "[1/7] Extracting SWI DICOM subjects (field 20219)..."
extract_eids "$UKB_SWI_DICOM_DIR" > "$OUTPUT_DIR/field_20219_swi_dicom.txt"
echo "  Found: $(wc -l < "$OUTPUT_DIR/field_20219_swi_dicom.txt") subjects"

echo "[2/7] Extracting T1 FIRST/FAST subjects (field 20252)..."
extract_eids "${UKB_T1_BASE}/20252" "${UKB_T1_BASE}/20252_ASHLEY" > "$OUTPUT_DIR/field_20252_t1.txt"
echo "  Found: $(wc -l < "$OUTPUT_DIR/field_20252_t1.txt") subjects"

echo "[3/7] Extracting T1 NIFTI subjects (field 20253)..."
extract_eids "${UKB_T1_BASE}/20253" "${UKB_T1_BASE}/20253_ASHLEY" > "$OUTPUT_DIR/field_20253_t1_nifti.txt"
echo "  Found: $(wc -l < "$OUTPUT_DIR/field_20253_t1_nifti.txt") subjects"

echo "[4/7] Extracting FreeSurfer subjects (field 20263)..."
# FreeSurfer has a different directory structure: 20263_part_*/batch_*
find "$UKB_FS_DIR"/20263_part_* -maxdepth 2 -name "*.zip" -printf '%f\n' 2>/dev/null \
    | cut -d_ -f1 | sort -u > "$OUTPUT_DIR/field_20263_freesurfer.txt"
echo "  Found: $(wc -l < "$OUTPUT_DIR/field_20263_freesurfer.txt") subjects"

echo "[5/7] Extracting SWI registration subjects (field 20251)..."
extract_eids "$UKB_SWI_REG_DIR" > "$OUTPUT_DIR/field_20251_swi_reg.txt"
echo "  Found: $(wc -l < "$OUTPUT_DIR/field_20251_swi_reg.txt") subjects"

echo "[6/7] Extracting UKB QSM processed subjects (field 26301)..."
extract_eids "$UKB_QSM_DIR" > "$OUTPUT_DIR/field_26301_ukb_qsm.txt"
echo "  Found: $(wc -l < "$OUTPUT_DIR/field_26301_ukb_qsm.txt") subjects"

echo "[7/7] Extracting QSMxT-processed subjects..."
ls "$QSMXT_OUTPUT_DIR" 2>/dev/null | grep '^sub-' | sed 's/^sub-//' | sort -u > "$OUTPUT_DIR/qsmxt_processed.txt"
echo "  Found: $(wc -l < "$OUTPUT_DIR/qsmxt_processed.txt") subjects"

echo ""
echo "========================================"
echo "Computing intersections"
echo "========================================"

# ---- Key intersections ----

# SWI + T1
comm -12 "$OUTPUT_DIR/field_20219_swi_dicom.txt" "$OUTPUT_DIR/field_20252_t1.txt" \
    > "$OUTPUT_DIR/intersection_swi_t1.txt"
echo "SWI + T1: $(wc -l < "$OUTPUT_DIR/intersection_swi_t1.txt")"

# SWI + T1 + UKB_QSM
comm -12 "$OUTPUT_DIR/intersection_swi_t1.txt" "$OUTPUT_DIR/field_26301_ukb_qsm.txt" \
    > "$OUTPUT_DIR/intersection_swi_t1_qsm.txt"
echo "SWI + T1 + UKB_QSM: $(wc -l < "$OUTPUT_DIR/intersection_swi_t1_qsm.txt")"

# SWI + T1 + UKB_QSM + SWI_reg (core comparison set)
comm -12 "$OUTPUT_DIR/intersection_swi_t1_qsm.txt" "$OUTPUT_DIR/field_20251_swi_reg.txt" \
    > "$OUTPUT_DIR/intersection_core.txt"
echo "SWI + T1 + UKB_QSM + SWI_reg (core): $(wc -l < "$OUTPUT_DIR/intersection_core.txt")"

# Core + FreeSurfer (full set)
comm -12 "$OUTPUT_DIR/intersection_core.txt" "$OUTPUT_DIR/field_20263_freesurfer.txt" \
    > "$OUTPUT_DIR/intersection_core_freesurfer.txt"
echo "Core + FreeSurfer: $(wc -l < "$OUTPUT_DIR/intersection_core_freesurfer.txt")"

# Core subjects MISSING FreeSurfer
comm -23 "$OUTPUT_DIR/intersection_core.txt" "$OUTPUT_DIR/field_20263_freesurfer.txt" \
    > "$OUTPUT_DIR/core_missing_freesurfer.txt"
echo "Core but MISSING FreeSurfer: $(wc -l < "$OUTPUT_DIR/core_missing_freesurfer.txt")"

# Of those missing FreeSurfer, which have T1 NIFTI for FastSurfer?
comm -12 "$OUTPUT_DIR/core_missing_freesurfer.txt" "$OUTPUT_DIR/field_20253_t1_nifti.txt" \
    > "$OUTPUT_DIR/core_missing_fs_have_t1nifti.txt"
echo "  ...of those, have T1 NIFTI for FastSurfer: $(wc -l < "$OUTPUT_DIR/core_missing_fs_have_t1nifti.txt")"

# QSMxT processed overlapping with core
comm -12 "$OUTPUT_DIR/qsmxt_processed.txt" "$OUTPUT_DIR/intersection_core.txt" \
    > "$OUTPUT_DIR/qsmxt_in_core.txt"
echo "QSMxT processed in core set: $(wc -l < "$OUTPUT_DIR/qsmxt_in_core.txt")"

# QSMxT processed overlapping with core + FreeSurfer
comm -12 "$OUTPUT_DIR/qsmxt_processed.txt" "$OUTPUT_DIR/intersection_core_freesurfer.txt" \
    > "$OUTPUT_DIR/qsmxt_in_core_freesurfer.txt"
echo "QSMxT processed in core + FreeSurfer: $(wc -l < "$OUTPUT_DIR/qsmxt_in_core_freesurfer.txt")"

# Core subjects NOT yet QSMxT-processed
comm -23 "$OUTPUT_DIR/intersection_core.txt" "$OUTPUT_DIR/qsmxt_processed.txt" \
    > "$OUTPUT_DIR/core_not_qsmxt_processed.txt"
echo "Core subjects NOT yet QSMxT-processed: $(wc -l < "$OUTPUT_DIR/core_not_qsmxt_processed.txt")"

echo ""
echo "========================================"
echo "Summary"
echo "========================================"

# Write summary file
cat > "$OUTPUT_DIR/SUMMARY.txt" <<SUMMARY
UKB-QSMxT Subject List Summary
Generated: $(date -Iseconds)

== Per-Field Counts ==
SWI DICOMs (20219):          $(wc -l < "$OUTPUT_DIR/field_20219_swi_dicom.txt")
T1 FIRST/FAST (20252):       $(wc -l < "$OUTPUT_DIR/field_20252_t1.txt")
T1 NIFTI (20253):            $(wc -l < "$OUTPUT_DIR/field_20253_t1_nifti.txt")
FreeSurfer (20263):           $(wc -l < "$OUTPUT_DIR/field_20263_freesurfer.txt")
SWI registration (20251):    $(wc -l < "$OUTPUT_DIR/field_20251_swi_reg.txt")
UKB QSM processed (26301):   $(wc -l < "$OUTPUT_DIR/field_26301_ukb_qsm.txt")
QSMxT processed:             $(wc -l < "$OUTPUT_DIR/qsmxt_processed.txt")

== Key Intersections ==
SWI + T1:                              $(wc -l < "$OUTPUT_DIR/intersection_swi_t1.txt")
SWI + T1 + UKB_QSM:                    $(wc -l < "$OUTPUT_DIR/intersection_swi_t1_qsm.txt")
SWI + T1 + UKB_QSM + SWI_reg (core):   $(wc -l < "$OUTPUT_DIR/intersection_core.txt")
Core + FreeSurfer:                      $(wc -l < "$OUTPUT_DIR/intersection_core_freesurfer.txt")

== Gap Analysis ==
Core but MISSING FreeSurfer:            $(wc -l < "$OUTPUT_DIR/core_missing_freesurfer.txt")
  ...with T1 NIFTI for FastSurfer:      $(wc -l < "$OUTPUT_DIR/core_missing_fs_have_t1nifti.txt")

== QSMxT Processing Progress ==
QSMxT processed in core set:            $(wc -l < "$OUTPUT_DIR/qsmxt_in_core.txt")
QSMxT processed in core + FreeSurfer:   $(wc -l < "$OUTPUT_DIR/qsmxt_in_core_freesurfer.txt")
Core NOT yet QSMxT-processed:           $(wc -l < "$OUTPUT_DIR/core_not_qsmxt_processed.txt")

== Output Files ==
Per-field subject lists:      field_*.txt
Key intersections:            intersection_*.txt
Gap analysis:                 core_missing_*.txt
QSMxT overlap:                qsmxt_*.txt
SUMMARY

cat "$OUTPUT_DIR/SUMMARY.txt"

echo ""
echo "All lists saved to: $OUTPUT_DIR/"
