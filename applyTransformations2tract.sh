#!/usr/bin/env bash
set -euo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: missing command: $1" >&2; exit 1; }; }

usage() {
  cat <<'EOF'
applyTransformations2tract.sh

Apply spatial transformations (ANTs or FSL-derived) to a tractogram using scilpy.

==============================================================================
REQUIRED
==============================================================================

  -i, --in TRACK              Input tractogram (.trk/.tck)
  -r, --reference IMAGE       Reference image (target space)

==============================================================================
AFFINE / WARP
==============================================================================

  -a, --affine MAT|None       Main ANTs affine (.mat) or ITK affine (.txt).
                              Use "None" if not applying affine.

  -w, --warp FIELD|None       Deformation field
                              (e.g., 1Warp.nii.gz or 1InverseWarp.nii.gz)

  -p, --pre-affine MAT        Optional pre-affine (.mat)

  -m, --moving IMAGE          Moving image
                              (required only if using --compose or --from-fsl)

==============================================================================
Composition (advanced)
==============================================================================

  -c, --compose MODE

        Compose --pre-affine and --affine into a single Linear[...] transform
        using antsApplyTransforms before applying to the tractogram.

        In ANTs syntax:
            -t [AFFINE,0]  → apply AFFINE forward
            -t [AFFINE,1]  → apply inverse(AFFINE)

        MODE defines:
            1) whether each affine is inverted
            2) the order they are passed to ANTs

        Order matters: ANTs applies transforms in the order provided.

        Modes:

          0 : pre_affine (forward),  affine (inverse)
              -t [pre_affine,0]  -t [affine,1]

          1 : pre_affine (forward),  affine (forward)
              -t [pre_affine,0]  -t [affine,0]

          2 : pre_affine (inverse),  affine (inverse)
              -t [pre_affine,1]  -t [affine,1]

          3 : pre_affine (forward),  affine (forward)
              (same inversion as mode 1; kept for backward compatibility)

          4 : pre_affine (inverse),  affine (forward)
              -t [pre_affine,1]  -t [affine,0]

          5 : pre_affine (inverse),  affine (inverse)
              (same inversion as mode 2; different internal ordering)

          6 : pre_affine (forward),  affine (inverse)
              (same inversion as mode 0; different internal ordering)

          7 : pre_affine (inverse),  affine (forward)
              (same inversion as mode 4; different internal ordering)

        NOTE:
          The difference between some modes (e.g. 0 vs 6) is the ordering
          in which ANTs receives the transforms. Since transform order
          changes the effective mapping, use with care.

        Scientific interpretation:
          Use inversion (1) when you need the backward mapping of that
          affine (e.g., moving→fixed vs fixed→moving space).

        IMPORTANT:
          If you are only applying a single affine (no --pre-affine),
          you DO NOT need --compose.

==============================================================================
AFFINE CONVERSION
==============================================================================

      --convert-affine
        Convert the FINAL affine (direct or composed) to AffineType using:

          ConvertTransformFile 3 AFFINE OUT.mat --convertToAffineType

==============================================================================
FSL -> ANTs/ITK CONVERSION (optional)
==============================================================================

      --from-fsl
        Treat inputs as FSL transforms and convert to ANTs/ITK-compatible
        transforms before applying.

        Requires:
          - c3d_affine_tool   (Convert3D / ITK-SNAP tools) to convert FLIRT affine
          - wb_command        (Connectome Workbench) to convert FNIRT warpfield

      --inverse-warp FIELD|None
        FNIRT inverse warpfield (used only with --from-fsl and --invert).

==============================================================================
SCILPY APPLICATION OPTIONS
==============================================================================

      --invert
        Pass --inverse to scil_apply_transform_to_tractogram.py.
        Applies the inverse of the LINEAR transform.

      --reverse-operation
        Pass --reverse_operation to scil_apply_transform_to_tractogram.py.
        Applies operations in reverse order (warp first, then linear), as in scilpy docs.

  -v, --verbose
        Pass --verbose to scil_apply_transform_to_tractogram.py (more output).

==============================================================================
OUTPUT
==============================================================================

  -o, --out TRACK             Output tractogram
                              (default: <input>_warped.<ext>)

==============================================================================
MINIMAL EXAMPLES (from scilpy documentation)
==============================================================================

Assume registration was performed as:

    MOVING  →  REFERENCE

This means the estimated transform maps MOVING space into REFERENCE space.


Case A)
Bring tractogram FROM MOVING → REFERENCE space

  Use:
    - inverse affine (--invert)
    - inverse warp (1InverseWarp.nii.gz)

  applyTransformations2tract.sh \
      --in        MOVING_TRACT.trk \
      --reference REFERENCE_IMAGE.nii.gz \
      --affine    0GenericAffine.mat \
      --warp      1InverseWarp.nii.gz \
      --out       tract_in_reference.trk \
      --invert


Case B)
Bring tractogram FROM REFERENCE → MOVING space

  Use:
    - forward affine (no --invert)
    - forward warp (1Warp.nii.gz)
    - reverse operation (warp first, then linear)

  applyTransformations2tract.sh \
      --in        REFERENCE_TRACT.trk \
      --reference REFERENCE_IMAGE.nii.gz \
      --affine    0GenericAffine.mat \
      --warp      1Warp.nii.gz \
      --out       tract_in_moving.trk \
      --reverse-operation

EOF
}

# --- deps ---
need_cmd antsApplyTransforms
need_cmd scil_apply_transform_to_tractogram.py
need_cmd getopt

# --- defaults ---
track_in=""
reference=""
affine2="None"
warp="None"
track_out=""
pre_affine=""
moving=""
compose_mode=""
invert_tract=0
convert_affine=0

# --- FSL conversion defaults ---
from_fsl=0
inverse_warp="None"

# --- new scilpy options defaults ---
reverse_operation=0
verbose=0

# --- parse args (GNU getopt for long options) ---
OPTS=$(getopt -o i:r:a:w:o:p:m:c:hv \
  --long in:,reference:,affine:,warp:,out:,pre-affine:,moving:,compose:,invert,convert-affine,from-fsl,inverse-warp:,reverse-operation,verbose,help \
  -n 'applyTransformations2tract' -- "$@")
if [[ $? -ne 0 ]]; then usage; exit 2; fi
eval set -- "$OPTS"

while true; do
  case "$1" in
    -i|--in)               track_in="$2"; shift 2 ;;
    -r|--reference)        reference="$2"; shift 2 ;;
    -a|--affine)           affine2="$2"; shift 2 ;;
    -w|--warp)             warp="$2"; shift 2 ;;
    -o|--out)              track_out="$2"; shift 2 ;;
    -p|--pre-affine)       pre_affine="$2"; shift 2 ;;
    -m|--moving)           moving="$2"; shift 2 ;;
    -c|--compose)          compose_mode="$2"; shift 2 ;;
    --invert)              invert_tract=1; shift ;;
    --convert-affine)      convert_affine=1; shift ;;
    --from-fsl)            from_fsl=1; shift ;;
    --inverse-warp)        inverse_warp="$2"; shift 2 ;;
    --reverse-operation)   reverse_operation=1; shift ;;
    -v|--verbose)          verbose=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Internal error parsing args" >&2; exit 3 ;;
  esac
done

# If conversion requested, require ConvertTransformFile
if [[ "$convert_affine" -eq 1 ]]; then
  need_cmd ConvertTransformFile
fi

# --- validate required ---
[[ -n "$track_in" ]] || { echo "Error: --in is required" >&2; usage; exit 1; }
[[ -n "$reference" ]] || { echo "Error: --reference is required" >&2; usage; exit 1; }

# --- default output name ---
if [[ -z "$track_out" ]]; then
  base="${track_in%.*}"
  ext="${track_in##*.}"
  track_out="${base}_warped.${ext}"
fi

# === Convert FSL transforms to ANTs/ITK if requested ===
if [[ "$from_fsl" -eq 1 ]]; then
  need_cmd c3d_affine_tool

  [[ -n "$moving" ]] || {
    echo "Error: --moving is required with --from-fsl (needed to convert FLIRT affine)" >&2
    exit 1
  }
  [[ "$affine2" != "None" ]] || {
    echo "Error: --affine must be provided (FLIRT .mat) when using --from-fsl" >&2
    exit 1
  }

  echo "[INFO] Converting FLIRT affine to ITK/ANTs..."
  affine_fsl="$affine2"
  affine_itk="${affine_fsl%.*}_itk.txt"
  c3d_affine_tool -ref "$reference" -src "$moving" "$affine_fsl" -fsl2ras -oitk "$affine_itk"
  affine2="$affine_itk"

  # Convert FNIRT warpfield if provided
  if [[ "$warp" != "None" || "$inverse_warp" != "None" ]]; then
    need_cmd wb_command

    if [[ "$invert_tract" -eq 1 ]]; then
      [[ "$inverse_warp" != "None" && -n "$inverse_warp" ]] || {
        echo "Error: --invert with --from-fsl requires --inverse-warp (FNIRT inverse warpfield)." >&2
        exit 1
      }
      warp_to_convert="$inverse_warp"
      warp_out="${warp_to_convert%.*}_itk.nii.gz"
      echo "[INFO] Converting FNIRT inverse warpfield to ITK..."
      wb_command -convert-warpfield -from-fnirt "$warp_to_convert" "$reference" -to-itk "$warp_out"
      warp="$warp_out"
    else
      if [[ "$warp" != "None" && -n "$warp" ]]; then
        warp_to_convert="$warp"
        warp_out="${warp_to_convert%.*}_itk.nii.gz"
        echo "[INFO] Converting FNIRT warpfield to ITK..."
        wb_command -convert-warpfield -from-fnirt "$warp_to_convert" "$reference" -to-itk "$warp_out"
        warp="$warp_out"
      fi
    fi
  fi
fi

# --- warp args for scilpy ---
warp_args=()
if [[ "$warp" != "None" && -n "$warp" ]]; then
  warp_args=(--in_deformation "$warp")
fi

# --- decide affine to use (direct or composed) ---
affine_to_use=""

tform() { echo "-t [${1},${2}]"; }

if [[ -n "$compose_mode" ]]; then
  # composition requested
  [[ "$compose_mode" =~ ^[0-7]$ ]] || { echo "Error: --compose must be 0..7" >&2; exit 1; }
  [[ -n "$moving" ]] || { echo "Error: --moving is required when using --compose" >&2; exit 1; }
  [[ -n "$pre_affine" ]] || { echo "Error: --pre-affine is required when using --compose" >&2; exit 1; }
  [[ "$affine2" != "None" ]] || { echo "Error: --affine must not be None when using --compose" >&2; exit 1; }

  comp_affine="${affine2%.*}_comp.${affine2##*.}"

  pre=""
  app=""

  case "$compose_mode" in
    0) pre="$(tform "$pre_affine" 0)"; app="$(tform "$affine2" 1)" ;;
    1) pre="$(tform "$pre_affine" 0)"; app="$(tform "$affine2" 0)" ;;
    2) pre="$(tform "$pre_affine" 1)"; app="$(tform "$affine2" 1)" ;;
    3) pre="$(tform "$pre_affine" 0)"; app="$(tform "$affine2" 0)" ;;
    4) pre="$(tform "$pre_affine" 1)"; app="$(tform "$affine2" 0)" ;;
    5) pre="$(tform "$pre_affine" 1)"; app="$(tform "$affine2" 1)" ;;
    6) pre="$(tform "$pre_affine" 0)"; app="$(tform "$affine2" 1)" ;;
    7) pre="$(tform "$pre_affine" 1)"; app="$(tform "$affine2" 0)" ;;
  esac

  ants_cmd=(antsApplyTransforms -d 3 -e 0
            -i "$moving"
            -o "Linear[$comp_affine]"
            -r "$reference")
  # split bracket tokens intentionally
  # shellcheck disable=SC2206
  ants_cmd+=($pre)
  # shellcheck disable=SC2206
  ants_cmd+=($app)

  echo "[INFO] Composing affines:"
  printf '  %q' "${ants_cmd[@]}"; echo
  "${ants_cmd[@]}"

  affine_to_use="$comp_affine"
else
  # no composition: use affine directly if provided
  if [[ "$affine2" != "None" && -n "$affine2" ]]; then
    affine_to_use="$affine2"
  else
    affine_to_use=""
  fi
fi

# --- ensure we have a linear transform for scilpy ---
[[ -n "$affine_to_use" ]] || {
  echo "Error: no affine specified. scil_apply_transform_to_tractogram.py typically requires a linear transform." >&2
  echo "       Provide --affine <mat>, or implement an identity affine." >&2
  exit 1
}

# --- optional: convert FINAL affine to AffineType for compatibility ---
if [[ "$convert_affine" -eq 1 ]]; then
  out_conv="${affine_to_use}"
  if [[ "$affine_to_use" == *.mat ]]; then
    out_conv="${affine_to_use%.mat}_converted.mat"
  else
    out_conv="${affine_to_use}_converted.mat"
  fi

  echo "[INFO] Converting affine with ConvertTransformFile:"
  echo "       ${affine_to_use} -> ${out_conv}"
  ConvertTransformFile 3 "$affine_to_use" "$out_conv" --convertToAffineType
  affine_to_use="$out_conv"
fi

# --- build scilpy command ---
# scil_apply_transform_to_tractogram.py positional order:
#   in_tractogram reference transform out_tractogram
scil_cmd=(scil_apply_transform_to_tractogram.py
          "$track_in"
          "$reference"
          "$affine_to_use"
          "$track_out"
          --reference "$reference"
          "${warp_args[@]}"
          -f
          --keep_invalid)

if [[ "$invert_tract" -eq 1 ]]; then
  scil_cmd+=(--inverse)
fi

if [[ "$reverse_operation" -eq 1 ]]; then
  scil_cmd+=(--reverse_operation)
fi

if [[ "$verbose" -eq 1 ]]; then
  scil_cmd+=(-v)
fi

echo "[INFO] Applying transform(s) to tractogram:"
printf '  %q' "${scil_cmd[@]}"; echo
"${scil_cmd[@]}"

echo "[INFO] Done: $track_out"