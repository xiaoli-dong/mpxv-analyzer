#!/bin/bash
#SBATCH --job-name=mpxv-analyzer-nanopore
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --partition=vm-cpu,big-ram,huge-ram
#SBATCH --time=3-00:00:00
#SBATCH --mem=24G
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.err

set -euo pipefail

# ==========================================================
# Help & usage
# ==========================================================

show_help() {
    cat << EOF
MPXV Nanopore SLURM submission script

USAGE:
 sbatch $0 <samplesheet.csv> <results_dir> [options]

REQUIRED:
  samplesheet.csv       Input samplesheet (CSV)
  results_dir           Output directory for pipeline results

OPTIONS:
  --qcflow-config FILE     Custom nf-qcflow config file
  -h, --help               Show this help

EXAMPLES:
  sbatch $0 samplesheet.csv results_dir

  sbatch $0 samplesheet.csv results_dir \
      --qcflow-config qcflow.config

CHECK HELP WITHOUT SUBMITTING:
  bash $0 --help

NOTES:
  • This script must be submitted with sbatch
  • SLURM stdout/stderr will be written to:
      slurm-<jobid>.out
      slurm-<jobid>.err

samplesheet example
    sample,fastq_1,fastq_2,long_fastq
    sid,NA,NA,long.fastq.gz

EOF
}

# Allow help without sbatch
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
esac

# ==========================================================
# Required arguments
# ==========================================================

if [[ $# -lt 2 ]]; then
    echo "ERROR: Missing required arguments"
    show_help
    exit 1
fi

SAMPLESHEET="$1"
RESULTS_DIR="$2"
shift 2

# Optional named arguments
QCFLOW_CONFIG=""

# ==========================================================
# Parse named options
# ==========================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qcflow-config)
            QCFLOW_CONFIG="${2:-}"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# ==========================================================
# Validation
# ==========================================================

if [[ ! -s "$SAMPLESHEET" ]]; then
    echo "ERROR: Samplesheet missing or empty: $SAMPLESHEET"
    exit 1
fi

validate_config() {
    local cfg="$1"
    local name="$2"

    if [[ -n "$cfg" ]]; then
        [[ -f "$cfg" ]] || { echo "ERROR: $name config not found: $cfg"; exit 1; }
        echo "$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"
    fi
}


QCFLOW_CONFIG="$(validate_config "$QCFLOW_CONFIG" "QCflow")"

# Resolve absolute paths
SAMPLESHEET="$(cd "$(dirname "$SAMPLESHEET")" && pwd)/$(basename "$SAMPLESHEET")"
RESULTS_DIR="$(mkdir -p "$RESULTS_DIR" && cd "$RESULTS_DIR" && pwd)"

# ==========================================================
# Logging
# ==========================================================

echo "=================================================="
echo "SLURM job ID        : ${SLURM_JOB_ID:-N/A}"
echo "Job name            : ${SLURM_JOB_NAME:-N/A}"
echo "Node(s)             : ${SLURM_NODELIST:-N/A}"
echo "CPUs per task       : ${SLURM_CPUS_PER_TASK:-N/A}"
echo "Samplesheet         : $SAMPLESHEET"
echo "Results directory   : $RESULTS_DIR"
[[ -n "$QCFLOW_CONFIG" ]] && echo "QCflow config       : $QCFLOW_CONFIG"
echo "Start time          : $(date)"
echo "=================================================="

prog_base="/nfs/Genomics_DEV/projects/xdong/deve/mpxv-analyzer"
# ==========================================================
# Conda setup (activate mode, NFS-safe)
# ==========================================================

ENV_NAME="mpxv-analyzer-env"
ENV_FILE="${prog_base}/env/environment.yml"

# Detect conda base dynamically
if command -v conda >/dev/null 2>&1; then
    CONDA_BASE="$(conda info --base)"
else
    echo "[ERROR] conda not found in PATH" >&2
    exit 1
fi

ENV_PATH="${CONDA_BASE}/envs/${ENV_NAME}"

echo "[INFO] Checking conda environment: $ENV_NAME"

# Initialize conda for non-interactive shell
if [[ -f "${CONDA_BASE}/etc/profile.d/conda.sh" ]]; then
    # shellcheck disable=SC1091
    source "${CONDA_BASE}/etc/profile.d/conda.sh"
else
    echo "[ERROR] conda.sh not found in ${CONDA_BASE}" >&2
    exit 1
fi

# Create environment if missing (check by path)
if [[ -d "$ENV_PATH" ]]; then
    echo "[INFO] Conda env exists: $ENV_PATH"
else
    echo "[INFO] Creating conda environment..."

    [[ -f "$ENV_FILE" ]] || { echo "[ERROR] Environment file not found: $ENV_FILE"; exit 1; }

    if ! mamba env create -f "$ENV_FILE" -p "$ENV_PATH"; then
        echo "[WARN] mamba failed, trying conda..."
        conda env create -f "$ENV_FILE" -p "$ENV_PATH" || {
            echo "[ERROR] Failed to create environment: $ENV_NAME"
            exit 1
        }
    fi
    echo "[INFO] Conda environment created"
fi

# Activate environment using full path
if ! conda activate "$ENV_PATH"; then
    echo "[ERROR] Failed to activate environment: $ENV_PATH"
    exit 1
fi

echo "[INFO] Activated conda environment: $ENV_PATH"

# ==========================================================
# Run pipeline
# ==========================================================

PIPELINE="${prog_base}/scripts/mpxv_nanopore_pipeline.sh"

[[ -f "$PIPELINE" ]] || { echo "ERROR: Pipeline script not found: $PIPELINE"; exit 1; }

CMD=(bash "$PIPELINE" "$SAMPLESHEET" "$RESULTS_DIR")
[[ -n "$QCFLOW_CONFIG" ]] && CMD+=(--qcflow-config "$QCFLOW_CONFIG")

echo "Running pipeline command:"
printf '  %q' "${CMD[@]}"
echo

"${CMD[@]}"
exit_code=$?

# ==========================================================
# Finish
# ==========================================================

echo "=================================================="
echo "Pipeline exit code  : $exit_code"
echo "End time            : $(date)"
echo "=================================================="

exit $exit_code
