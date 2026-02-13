#!/usr/bin/env python3
"""
FLAIR Lesion Segmentation Viewer

Generates PNG previews of FLAIR images with lesion segmentation overlays.
Automatically selects a representative axial slice based on segmentation content.
"""

import glob
import os
from pathlib import Path

import nibabel as nib
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap

# =============================================================================
# CONFIGURE THESE GLOB PATTERNS
# =============================================================================

# Glob pattern for FLAIR images (or other anatomical images)
FLAIR_PATTERN = "data/challenges/20170327_qsm2016_recon_challenge/bids/sub-*/anat/*_part-mag_T2starw.nii.gz"

# Glob pattern for segmentations (must match FLAIR images by sorted order)
SEGMENTATION_PATTERN = "data/challenges/20170327_qsm2016_recon_challenge/bids/derivatives/2016-challenge-code/sub-*/anat/*_dseg.nii.gz"

# Get sorted file lists (sorting ensures FLAIR/seg pairs match up)
FLAIR_IMAGES = sorted(glob.glob(FLAIR_PATTERN, recursive=True))
SEGMENTATIONS = sorted(glob.glob(SEGMENTATION_PATTERN, recursive=True))

# =============================================================================
# PARAMETERS
# =============================================================================

# Slice selection: "median" picks slice closest to median voxel count,
# "random_above_median" picks randomly from slices at or above median
SLICE_SELECTION_METHOD = "median"

# Percentile windowing for FLAIR images
WINDOW_PERCENTILE_LOW = 5
WINDOW_PERCENTILE_HIGH = 95

# Segmentation overlay opacity
OVERLAY_ALPHA = 0.85

# Output directory (None = current working directory)
OUTPUT_DIR = None


# =============================================================================
# IMPLEMENTATION
# =============================================================================

def get_qualitative_cmap(n_labels):
    """
    Get a qualitative colormap suitable for discrete segmentation labels.
    Uses tab10/tab20 for good visual separation.
    """
    if n_labels <= 10:
        base_cmap = plt.cm.tab10
    else:
        base_cmap = plt.cm.tab20

    # Create colormap with transparent background (label 0)
    colors = [(0, 0, 0, 0)]  # Transparent for background
    for i in range(1, n_labels + 1):
        color = list(base_cmap(i % base_cmap.N))
        color[3] = OVERLAY_ALPHA  # Set alpha
        colors.append(tuple(color))

    return ListedColormap(colors)


def select_axial_slice(seg_data, method="median"):
    """
    Select a representative axial slice based on segmentation content.

    Parameters
    ----------
    seg_data : np.ndarray
        3D segmentation array (assumes axis 2 is axial)
    method : str
        "median" - select slice closest to median voxel count
        "random_above_median" - randomly select from slices >= median

    Returns
    -------
    int
        Selected slice index, or None if no segmentation present
    """
    n_slices = seg_data.shape[2]

    # Count non-zero voxels per axial slice
    voxel_counts = []
    slice_indices = []

    for z in range(n_slices):
        count = np.sum(seg_data[:, :, z] > 0)
        if count > 0:
            voxel_counts.append(count)
            slice_indices.append(z)

    if len(voxel_counts) == 0:
        return None

    voxel_counts = np.array(voxel_counts)
    slice_indices = np.array(slice_indices)

    median_count = np.median(voxel_counts)

    if method == "median":
        # Find slice closest to median voxel count
        distances = np.abs(voxel_counts - median_count)
        best_idx = np.argmin(distances)
        return slice_indices[best_idx]

    elif method == "random_above_median":
        # Randomly select from slices at or above median
        above_median_mask = voxel_counts >= median_count
        candidates = slice_indices[above_median_mask]
        return np.random.choice(candidates)

    else:
        raise ValueError(f"Unknown slice selection method: {method}")


def window_image(img_data, low_pct=5, high_pct=95):
    """
    Apply percentile-based windowing to image data.
    """
    low_val = np.percentile(img_data, low_pct)
    high_val = np.percentile(img_data, high_pct)

    windowed = np.clip(img_data, low_val, high_val)
    windowed = (windowed - low_val) / (high_val - low_val + 1e-8)

    return windowed


def create_overlay_figure(flair_slice, seg_slice, n_labels):
    """
    Create a side-by-side figure: raw FLAIR on left, overlay on right.
    """
    fig, axes = plt.subplots(1, 2, figsize=(12, 6))

    # Left: Raw FLAIR slice
    axes[0].imshow(flair_slice.T, cmap="gray", origin="lower")
    axes[0].set_title("FLAIR")
    axes[0].axis("off")

    # Right: FLAIR with segmentation overlay
    axes[1].imshow(flair_slice.T, cmap="gray", origin="lower")

    # Only show overlay where segmentation exists
    seg_masked = np.ma.masked_where(seg_slice == 0, seg_slice)
    cmap = get_qualitative_cmap(n_labels)
    axes[1].imshow(seg_masked.T, cmap=cmap, origin="lower",
                   vmin=0, vmax=n_labels, interpolation="nearest")
    axes[1].set_title("FLAIR + Segmentation")
    axes[1].axis("off")

    plt.tight_layout()
    return fig


def process_pair(flair_path, seg_path, output_dir, method="median"):
    """
    Process a single FLAIR/segmentation pair and save PNG.

    Returns
    -------
    str or None
        Output path if successful, None if skipped
    """
    flair_path = Path(flair_path)
    seg_path = Path(seg_path)

    # Load data
    flair_img = nib.load(flair_path)
    seg_img = nib.load(seg_path)

    flair_data = flair_img.get_fdata()
    seg_data = seg_img.get_fdata().astype(int)

    # Verify shapes match
    if flair_data.shape != seg_data.shape:
        print(f"WARNING: Shape mismatch for {flair_path.name}")
        print(f"  FLAIR: {flair_data.shape}, Seg: {seg_data.shape}")
        return None

    # Select slice
    slice_idx = select_axial_slice(seg_data, method=method)

    if slice_idx is None:
        print(f"WARNING: No segmentation found in {seg_path.name}, skipping")
        return None

    # Extract slices
    flair_slice = flair_data[:, :, slice_idx]
    seg_slice = seg_data[:, :, slice_idx]

    # Window FLAIR
    flair_windowed = window_image(
        flair_slice,
        low_pct=WINDOW_PERCENTILE_LOW,
        high_pct=WINDOW_PERCENTILE_HIGH
    )

    # Get number of unique labels (excluding 0)
    unique_labels = np.unique(seg_data)
    n_labels = int(unique_labels[unique_labels > 0].max()) if len(unique_labels) > 1 else 1

    # Create figure
    fig = create_overlay_figure(flair_windowed, seg_slice, n_labels)

    # Generate output filename
    stem = flair_path.name.replace(".nii.gz", "").replace(".nii", "")
    output_path = Path(output_dir) / f"{stem}_segmentation_preview.png"

    fig.savefig(output_path, dpi=150, bbox_inches="tight", facecolor="black")
    plt.close(fig)

    return str(output_path)


def main():
    """Main entry point."""
    if len(FLAIR_IMAGES) != len(SEGMENTATIONS):
        raise ValueError(
            f"Mismatch: {len(FLAIR_IMAGES)} FLAIR images but "
            f"{len(SEGMENTATIONS)} segmentations"
        )

    output_dir = OUTPUT_DIR or os.getcwd()
    os.makedirs(output_dir, exist_ok=True)

    print(f"Processing {len(FLAIR_IMAGES)} image pairs...")
    print(f"Slice selection method: {SLICE_SELECTION_METHOD}")
    print(f"Output directory: {output_dir}")
    print()

    successful = 0
    for i, (flair_path, seg_path) in enumerate(zip(FLAIR_IMAGES, SEGMENTATIONS)):
        print(f"[{i+1}/{len(FLAIR_IMAGES)}] Processing {Path(flair_path).name}...")

        result = process_pair(
            flair_path,
            seg_path,
            output_dir,
            method=SLICE_SELECTION_METHOD
        )

        if result:
            print(f"  -> Saved: {result}")
            successful += 1

    print()
    print(f"Done! Successfully processed {successful}/{len(FLAIR_IMAGES)} pairs.")


if __name__ == "__main__":
    main()
