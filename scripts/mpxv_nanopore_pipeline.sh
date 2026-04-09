#!/bin/bash
set -euo pipefail

# ==========================================================
# Paths & constants
# ==========================================================
readonly prod_prog_base="/nfs/APL_Genomics/apps/production"
readonly deve_prog_base="/nfs/Genomics_DEV/projects/xdong/deve"

# Define paths to the pipelines that mpox-analyzer depends on
readonly path_to_qc_pipeline="${prod_prog_base}/qcflow_pipeline/nf-qcflow"
readonly path_to_covflow="${prod_prog_base}/covflow_pipeline/nf-covflow"
readonly path_to_artic_nanopore_pipeline="${deve_prog_base}/artic-mpxv-nf/artic-mpxv-nf"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MPOX_PROG_BASE="${SCRIPT_DIR}/.."
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Database and reference files
readonly ref="${MPOX_PROG_BASE}/db/bccdc-mpox_2500_v2.3.0_reference.fasta"
readonly bed="${MPOX_PROG_BASE}/db/bccdc-mpox_2500_v2.3.0_primer.bed"
readonly scheme_name="bccdc-mpox/2500/v2.3.0"

# nf-qc config (default + override)
readonly DEFAULT_QCFLOW_CONFIG_FILE="${MPOX_PROG_BASE}/conf/qcflow.config"
QCFLOW_CONFIG_FILE="$DEFAULT_QCFLOW_CONFIG_FILE"

readonly VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")"
readonly AUTHOR="Xiaoli Dong, ProvLab - South, Calgary, AB, Canada"

# consensus completeness cutoff for better clade assignment and mutation profiling
COMPLETENESS_THRESHOLD="0.8"

# ==========================================================
# Help / Version
# ==========================================================
show_version() {
    echo "$SCRIPT_NAME"
    echo "version $VERSION"
    echo "Author: $AUTHOR"
    echo "Last updated: 2026-04-06"
    echo "GitHub:"
}

show_help() {
    cat << EOF
$0 - MPXV Nanopore analysis pipeline

Version: $VERSION
Author: $AUTHOR

USAGE:
 bash $0 <samplesheet.csv> <results_dir> [options]

REQUIRED:
  samplesheet.csv       Input samplesheet (CSV)
  results_dir           Output directory for pipeline results

Options:
  -h, --help
  -v, --version
  --qcflow-config FILE   Custom qcflow config
  --completeness FLOAT     Consensus completeness cutoff (default: 0.8)

EXAMPLES:
  sh $0 samplesheet.csv results

  sh $0 samplesheet.csv results \
      --qcflow-config qcflow.config

CHECK HELP WITHOUT SUBMITTING:
  bash $0 --help

CHECK VERSION WITHOUT SUBMITTING:
    bash $0 --version

EOF
}

# Allow help without sbatch
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
    ;;
    -v|--version)
        show_version
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
        --completeness)
            COMPLETENESS_THRESHOLD="${2:-}"
            shift 2
        ;;
        -h|--help)
            show_help
            exit 0
        ;;
        -v|--version)
            show_version
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
        if [[ ! -f "$cfg" ]]; then
            echo "ERROR: $name config not found: $cfg"
            exit 1
        fi
        if [[ ! -s "$cfg" ]]; then
            echo "WARNING: $name config is empty: $cfg"
        fi
        echo "$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"
    fi
}

QCFLOW_CONFIG="$(validate_config "$QCFLOW_CONFIG" "QCflow")"

if [[ -n "$QCFLOW_CONFIG" ]]; then
    QCFLOW_CONFIG_FILE="$QCFLOW_CONFIG"
fi

# Resolve absolute paths
SAMPLESHEET="$(cd "$(dirname "$SAMPLESHEET")" && pwd)/$(basename "$SAMPLESHEET")"
RESULTS_DIR="$(mkdir -p "$RESULTS_DIR" && cd "$RESULTS_DIR" && pwd)"

# ==========================================================
# Logging & helpers
# ==========================================================
LOGFILE="$RESULTS_DIR/pipeline.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME-$VERSION] $*"
    echo "$msg" >> "$LOGFILE"
}

error_exit() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME-$VERSION] ERROR: $1"
    echo "$msg" >&2
    exit "${2:-1}"
}

run_cmd() {
    log "Running: $*"

    {
        echo "----- CMD START: $(date) -----"
        echo "$*"
    } >> "$LOGFILE"

    "$@"
    local status=$?

    {
        echo "----- CMD END: $(date) [exit=$status] -----"
    } >> "$LOGFILE"

    [[ $status -eq 0 ]] || error_exit "Command failed: $*"
}

# ==========================================================
# Validation
# ==========================================================

log "Input samplesheet      : $SAMPLESHEET"
log "Results directory      : $RESULTS_DIR"
log "QCflow config file     : $QCFLOW_CONFIG_FILE"

# ==========================================================
# STEP 1: Prepare samplesheet
# ==========================================================
log "=== STEP 1: Preparing samplesheet ==="

ss="$RESULTS_DIR/samplesheet_to_qc.csv"
run_cmd cp "$SAMPLESHEET" "$ss"

[[ -s "$ss" ]] || { log "No $virus samples found, skipping"; return; }

# ==========================================================
# STEP 2: QC pipeline
# ==========================================================
log "=== STEP 2: Running QC pipeline ==="

run_cmd nextflow run "${path_to_qc_pipeline}/main.nf" \
-profile singularity,slurm \
-c "$QCFLOW_CONFIG_FILE" \
--input "$ss" \
--platform nanopore \
--outdir "$RESULTS_DIR/nf-qcflow" \
-resume


mkdir -p "$RESULTS_DIR/fastq_to_artic"
echo "barcode,sample_name,alias,type" > $RESULTS_DIR/fastq_to_artic/samplesheet.csv

for f in $RESULTS_DIR/nf-qcflow/qcreads/*.fastq.gz; do
    base=$(basename "$f" .deacon.fastq.gz)

    mkdir -p "$RESULTS_DIR/fastq_to_artic/$base"
    cp "$f" "$RESULTS_DIR/fastq_to_artic/$base/"

    echo "$base,$base,$base,test_sample" >> "$RESULTS_DIR/fastq_to_artic/samplesheet.csv"
done

# ==========================================================
# STEP 3: artic nanopore pipeline
# ==========================================================
log "=== STEP 3: Running Artic Nanopore pipeline ==="

# for singularity, clair3 model is under "/usr/local/bin/models"
# fastq dir subdir name must be barcodexx
artic_outdir="$RESULTS_DIR/artic-mpxv-nf"
run_cmd nextflow run ${path_to_artic_nanopore_pipeline}/main.nf \
-profile singularity,slurm \
--fastq $RESULTS_DIR/fastq_to_artic \
--scheme_version bccdc-mpox/2500/v2.3.0 \
--sample_sheet $RESULTS_DIR/fastq_to_artic/samplesheet.csv \
--out_dir $artic_outdir \
--skip_squirrel true \
--override_model_dir /usr/local/bin/models \
-resume

# ==========================================================
# STEP 4: nf-covflow pipeline
# ==========================================================
log "=== STEP 4: Running nf-covflow pipeline ==="

run_cmd mkdir -p $RESULTS_DIR/bam_to_covflow
run_cmd cp ${artic_outdir}/*.primertrimmed.rg.sorted.bam* $RESULTS_DIR/bam_to_covflow

run_cmd python "$SCRIPT_DIR/build_samplesheet_for_covflow.py" \
--input_dir "${RESULTS_DIR}/bam_to_covflow" \
--ref_fasta "$ref" \
--bed_file "$bed" \
-o "$RESULTS_DIR/samplesheet_to_covflow.csv"

run_cmd nextflow run "${path_to_covflow}/main.nf" \
-profile singularity,slurm \
--input "$RESULTS_DIR/samplesheet_to_covflow.csv" \
--outdir "$RESULTS_DIR/nf-covflow" \
-resume

# ==========================================================
# STEP 5: making summary report directory and copy the key
# outputs from different steps to this directory
# for easier access and downstream analysis, such as clade
# assignment and mutation profiling
# ==========================================================
log "=== STEP 5: Preparing final report directory ==="

final_report_dir="$RESULTS_DIR/summary_report"
mkdir -p "$final_report_dir"
mkdir -p "$final_report_dir/qc_plots"

#qcflow outputs
cp "$RESULTS_DIR/nf-qcflow/report/reads_nanopore.qc_report.csv" "$final_report_dir/"
cp "$RESULTS_DIR/nf-qcflow/report/reads_nanopore.topmatches.csv" "$final_report_dir/"

#artic outputs
cp $RESULTS_DIR/artic-mpxv-nf/all_consensus.* $final_report_dir/
cp $RESULTS_DIR/artic-mpxv-nf/*amplicon_depths.tsv $final_report_dir/
cp $RESULTS_DIR/artic-mpxv-nf/*normalised.named.vcf.gz* $final_report_dir/
cp -r $RESULTS_DIR/nf-covflow/report/* "$final_report_dir/" || true


# Consensus stats
run_cmd  python $SCRIPT_DIR/fasta_stats.py \
${final_report_dir}/all_consensus.fasta \
-o ${final_report_dir}/all_consensus.stats.tsv

# ==========================================================
# STEP 6: Filter consensus sequences by completeness
# default completeness cutoff is 80% for better clade
# assignment and mutation profiling
# ==========================================================
log "=== STEP 6: Filter consensus sequences by completeness"

stats_file="${final_report_dir}/all_consensus.stats.tsv"
consensus_fasta="${final_report_dir}/all_consensus.fasta"
filtered_fasta="${final_report_dir}/all_consensus.high_quality.fasta"

# Extract high-quality sample IDs
# suggested commpletenss for clade assignment is 80%, fiter out the
# sequences with completeness < 80% to avoid clade assignment failure and misclassification

run_cmd python $SCRIPT_DIR/filter_consensus.py \
--stats ${stats_file} \
--fasta ${consensus_fasta} \
--output ${filtered_fasta} \
--cutoff ${COMPLETENESS_THRESHOLD} \
--id_out ${final_report_dir}/all_consensus.high_quality_ids.txt

# ==========================================================
# STEP 7: Running nextclade assignment
# ==========================================================
log "=== STEP 7: Running Nextclade ==="

nextclade_db="nextstrain/mpox/all-clades"
run_cmd nextclade dataset get \
--name "nextstrain/mpox/all-clades" \
--output-dir "$nextclade_db"

run_cmd nextclade run "$filtered_fasta" \
-d "$nextclade_db" \
--output-all "$final_report_dir/nextclade" \
--output-selection json,ndjson,csv,tsv,tree,tree-nwk,gff,tbl

# ==========================================================
# STEP 8: Running Squirrel
# recommended to inspect the flagged sites in an aligment viewer to
# confirm they look like errors and then rerun the analysis by providing
# the generated csv file via --additional-mask to apply the masks before the
# final tree is built.
# ==========================================================
log "=== STEP 8: Running Squirrel ==="

run_cmd squirrel \
-t 8 \
"$filtered_fasta" \
--outdir "$final_report_dir/squirrel" \
--tempdir "$final_report_dir/squirrel_tmp" \
--clade split \
--seq-qc \
--run-apobec3-phylo \
--include-background \
--tree-file squirrel_tree

# ==========================================================
# STEP 9: make_summary_report
# ==========================================================
log "=== STEP 9: Making summary report ==="

cd "$final_report_dir" || error_exit "Failed to cd to summary report dir"

run_cmd python "$SCRIPT_DIR/make_summary_report.py" \
--qc reads_nanopore.qc_report.csv \
--consensus all_consensus.stats.tsv \
--depth chromosome_coverage_depth_summary.tsv \
--nextclade nextclade/nextclade.tsv \
--out mpxv_master.tsv

# ==========================================================
# Cleanup
# ==========================================================
log "=== PIPELINE COMPLETED SUCCESSFULLY ==="
log "Pipeline version: $VERSION"
log "Results directory: $RESULTS_DIR"
log "Finished at: $(date)"
exit 0
