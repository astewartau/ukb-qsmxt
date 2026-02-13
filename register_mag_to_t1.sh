#!/bin/bash
#
# Register magnitude image to T1 space
#
# This script:
#   1. Applies homogeneity correction to magnitude (optional, using Julia/MriResearchTools)
#   2. Registers magnitude to T1 using ANTs (affine-only by default)
#
# Requirements:
#   - ANTs (antsRegistrationSyNQuick.sh in PATH)
#   - Julia with MriResearchTools package (for homogeneity correction)
#
# Usage:
#   ./register_mag_to_t1.sh <magnitude.nii> <t1.nii.gz> <output_prefix> [options]
#
# Options:
#   --no-correction    Skip homogeneity correction
#   --syn              Use SyN (deformable) registration instead of affine-only
#   --threads N        Number of threads for ANTs (default: 4)
#
# Example:
#   ./register_mag_to_t1.sh mag.nii T1.nii.gz output/mag_to_t1_
#   ./register_mag_to_t1.sh mag.nii T1.nii.gz output/mag_to_t1_ --no-correction
#   ./register_mag_to_t1.sh mag.nii T1.nii.gz output/mag_to_t1_ --syn --threads 8

set -e

# Default options
DO_CORRECTION=true
TRANSFORM_TYPE="a"  # a = affine only, s = SyN (deformable)
THREADS=4

# Parse arguments
if [ $# -lt 3 ]; then
    echo "Usage: $0 <magnitude.nii> <t1.nii.gz> <output_prefix> [options]"
    echo ""
    echo "Options:"
    echo "  --no-correction    Skip homogeneity correction"
    echo "  --syn              Use SyN (deformable) registration instead of affine-only"
    echo "  --threads N        Number of threads for ANTs (default: 4)"
    exit 1
fi

MAG_INPUT="$1"
T1_INPUT="$2"
OUTPUT_PREFIX="$3"
shift 3

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-correction)
            DO_CORRECTION=false
            shift
            ;;
        --syn)
            TRANSFORM_TYPE="s"
            shift
            ;;
        --threads)
            THREADS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check inputs exist
if [ ! -f "$MAG_INPUT" ]; then
    echo "Error: Magnitude file not found: $MAG_INPUT"
    exit 1
fi

if [ ! -f "$T1_INPUT" ]; then
    echo "Error: T1 file not found: $T1_INPUT"
    exit 1
fi

# Create output directory if needed
OUTPUT_DIR=$(dirname "$OUTPUT_PREFIX")
if [ ! -d "$OUTPUT_DIR" ] && [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
fi

# Determine which magnitude to use for registration
if [ "$DO_CORRECTION" = true ]; then
    echo "=== Step 1: Applying homogeneity correction ==="

    # Create corrected magnitude filename
    MAG_CORRECTED="${OUTPUT_PREFIX}mag_corrected.nii"

    # Run Julia homogeneity correction
    julia --quiet -e "
using MriResearchTools

println(\"Loading magnitude: $MAG_INPUT\")
mag = readmag(\"$MAG_INPUT\")

println(\"Applying homogeneity correction (sigma=[20,20,10])...\")
corrected = makehomogeneous(Float32.(mag); sigma=[20, 20, 10])

println(\"Saving corrected magnitude: $MAG_CORRECTED\")
savenii(corrected, \"$(basename "$MAG_CORRECTED")\", \"$(dirname "$MAG_CORRECTED")\", header(mag))

println(\"Homogeneity correction complete.\")
"

    MAG_FOR_REG="$MAG_CORRECTED"
    echo "Using corrected magnitude for registration"
else
    MAG_FOR_REG="$MAG_INPUT"
    echo "=== Skipping homogeneity correction ==="
    echo "Using original magnitude for registration"
fi

echo ""
echo "=== Step 2: Running ANTs registration ==="
echo "  Fixed (target): $T1_INPUT"
echo "  Moving (source): $MAG_FOR_REG"
echo "  Transform type: $TRANSFORM_TYPE (a=affine, s=SyN)"
echo "  Threads: $THREADS"
echo ""

antsRegistrationSyNQuick.sh \
    -d 3 \
    -f "$T1_INPUT" \
    -m "$MAG_FOR_REG" \
    -o "$OUTPUT_PREFIX" \
    -t "$TRANSFORM_TYPE" \
    -n "$THREADS"

echo ""
echo "=== Registration complete ==="
echo ""
echo "Output files:"
echo "  Registered magnitude: ${OUTPUT_PREFIX}Warped.nii.gz"
echo "  Affine transform:     ${OUTPUT_PREFIX}0GenericAffine.mat"
if [ "$TRANSFORM_TYPE" = "s" ]; then
    echo "  Warp field:           ${OUTPUT_PREFIX}1Warp.nii.gz"
    echo "  Inverse warp:         ${OUTPUT_PREFIX}1InverseWarp.nii.gz"
fi
if [ "$DO_CORRECTION" = true ]; then
    echo "  Corrected magnitude:  $MAG_CORRECTED"
fi
