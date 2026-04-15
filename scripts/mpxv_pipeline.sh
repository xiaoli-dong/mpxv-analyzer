#!/bin/bash
set -euo pipefail

# ==========================================================
# Defaults
# ==========================================================
PLATFORM="illumina"
COMPLETENESS_THRESHOLD="0.8"

# ==========================================================
# Paths & constants
# ==========================================================
readonly prod_prog_base="/nfs/APL_Genomics/apps/production"
readonly deve_prog_base="/nfs/Genomics_DEV/projects/xdong/deve"

readonly path_to_qc_pipeline="${prod_prog_base}/qcflow_pipeline/nf-qcflow"
readonly path_to_covflow="${prod_prog_base}/covflow_pipeline/nf-covflow"
readonly path_to_artic_illumina_pipeline="${prod_prog_base}/artic-mpxv-illumina-nf"
readonly path_to_artic_nanopore_pipeline="${prod_prog_base}/artic-mpxv-nf"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

readonly ref="${SCRIPT_DIR}/../db/bccdc-mpox_2500_v2.3.0_reference.fasta"
readonly bed="${SCRIPT_DIR}/../db/bccdc-mpox_2500_v2.3.0_primer.bed"

readonly DEFAULT_QCFLOW_CONFIG_FILE="${SCRIPT_DIR}/../conf/qcflow.config"
QCFLOW_CONFIG_FILE="$DEFAULT_QCFLOW_CONFIG_FILE"

readonly VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")"
readonly AUTHOR="Xiaoli Dong, ProvLab - South, Calgary, AB, Canada"

# ==========================================================
# Help / Version
# ==========================================================
show_version() {
    echo "$SCRIPT_NAME"
    echo "version $VERSION"
    echo "author: $AUTHOR"
}

show_help() {
cat << EOF
Usage:
  bash $0 <samplesheet.csv> <results_dir> [options]

Options:
  --platform illumina|nanopore
  --qcflow-config FILE
  --completeness FLOAT
  -h|--help
  -v|--version
EOF
}

case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
    -v|--version) show_version; exit 0 ;;
esac

# ==========================================================
# Args
# ==========================================================
[[ $# -lt 2 ]] && { show_help; exit 1; }

SAMPLESHEET="$1"
RESULTS_DIR="$2"
shift 2

QCFLOW_CONFIG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qcflow-config) QCFLOW_CONFIG="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --completeness) COMPLETENESS_THRESHOLD="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ==========================================================
# Validation
# ==========================================================
[[ ! -s "$SAMPLESHEET" ]] && { echo "ERROR: invalid samplesheet"; exit 1; }

SAMPLESHEET="$(realpath "$SAMPLESHEET")"
RESULTS_DIR="$(mkdir -p "$RESULTS_DIR" && realpath "$RESULTS_DIR")"

LOGFILE="$RESULTS_DIR/pipeline.log"

log() {
    echo "[$(date '+%F %T')] [$SCRIPT_NAME] $*" >> "$LOGFILE"
}

run_cmd() {
    log "RUN: $*"
    "$@"
}

log "Starting pipeline"
log "Started at: $(date)"
log "Platform: $PLATFORM"
log "Results: $RESULTS_DIR"

# ==========================================================
# STEP 1: QC
# ==========================================================
log "STEP 1 QC"

ss="$RESULTS_DIR/samplesheet_to_qc.csv"
run_cmd cp "$SAMPLESHEET" "$ss"

run_cmd nextflow run "${path_to_qc_pipeline}/main.nf" \
-profile singularity,slurm \
-c "$QCFLOW_CONFIG_FILE" \
--input "$ss" \
--platform "$PLATFORM" \
--outdir "$RESULTS_DIR/nf-qcflow" \
-resume

# ==========================================================
# STEP 2: ARTIC
# ==========================================================
log "STEP 2 ARTIC ($PLATFORM)"

ARTIC_DIR="$RESULTS_DIR/artic"

if [[ "$PLATFORM" == "illumina" ]]; then
    prefix="artic_mpxv_illumina"
    run_cmd nextflow run "${path_to_artic_illumina_pipeline}/main.nf" \
    --directory "$RESULTS_DIR/nf-qcflow/qcreads" \
    --scheme_name "bccdc-mpox/2500/v2.3.0" \
    --outdir "$ARTIC_DIR" \
    -profile singularity,slurm \
    --skip_host_filter true \
    --skip_squirrel true \
    --skip_trim true \
    --prefix $prefix \
    -resume

    BAM_SRC=("$ARTIC_DIR"/sequenceAnalysis_align_trim/*.bam*)
    VCF_SRC=("$ARTIC_DIR"/sequenceAnalysis_callConsensusFreebayes/*vcf*)
    CONSENSUS="$ARTIC_DIR"/$prefix.all_consensus.fasta

    elif [[ "$PLATFORM" == "nanopore" ]]; then

    mkdir -p "$RESULTS_DIR/fastq_to_artic"
    echo "barcode,sample_name,alias,type" > "$RESULTS_DIR/fastq_to_artic/samplesheet.csv"

    for f in "$RESULTS_DIR"/nf-qcflow/qcreads/*.fastq.gz; do
        #[[ -e "$f" ]] || continue
        base=$(basename "$f" .deacon.fastq.gz)
        #base="${base#*-}"; # remove barcode prefix if present
        mkdir -p "$RESULTS_DIR/fastq_to_artic/$base"
        cp "$f" "$RESULTS_DIR/fastq_to_artic/$base/"

        echo "$base,$base,$base,test_sample" >> "$RESULTS_DIR/fastq_to_artic/samplesheet.csv"
    done

    run_cmd nextflow run ${path_to_artic_nanopore_pipeline}/main.nf \
    -profile singularity,slurm \
    --fastq $RESULTS_DIR/fastq_to_artic \
    --scheme_version bccdc-mpox/2500/v2.3.0 \
    --sample_sheet $RESULTS_DIR/fastq_to_artic/samplesheet.csv \
    --out_dir ${ARTIC_DIR} \
    --skip_squirrel true \
    --override_model_dir /usr/local/bin/models \
    -resume

    BAM_SRC=("$ARTIC_DIR"/*.primertrimmed.rg.sorted.bam*)
    VCF_SRC=("$ARTIC_DIR"/*vcf*)
    CONSENSUS="$ARTIC_DIR"/all_consensus.fasta
fi

# ==========================================================
# STEP 3: COVFLOW
# ==========================================================
log "STEP 3 COVFLOW"

run_cmd mkdir -p "$RESULTS_DIR/bam_to_covflow"
run_cmd cp "${BAM_SRC[@]}" "$RESULTS_DIR/bam_to_covflow/"

run_cmd python "$SCRIPT_DIR/build_samplesheet_for_covflow.py" \
--input_dir "$RESULTS_DIR/bam_to_covflow" \
--ref_fasta "$ref" \
--bed_file "$bed" \
-o "$RESULTS_DIR/samplesheet_to_covflow.csv"

run_cmd nextflow run "${path_to_covflow}/main.nf" \
-profile singularity,slurm \
--input "$RESULTS_DIR/samplesheet_to_covflow.csv" \
--outdir "$RESULTS_DIR/nf-covflow" \
-resume

# ==========================================================
# STEP 4: SUMMARY
# ==========================================================
log "STEP 4 SUMMARY"

FINAL="$RESULTS_DIR/summary_report"
run_cmd mkdir -p "$FINAL/bams" "$FINAL/vcfs"

run_cmd cp "${BAM_SRC[@]}" "$FINAL/bams/" 2>/dev/null || true
run_cmd cp "${VCF_SRC[@]}" "$FINAL/vcfs/" 2>/dev/null || true
run_cmd cp "$CONSENSUS" "$FINAL/all_consensus.fasta" 2>/dev/null || true

QC_FILE="reads_${PLATFORM}.qc_report.csv"
run_cmd cp "$RESULTS_DIR/nf-qcflow/report/$QC_FILE" "$FINAL/" 2>/dev/null || true
run_cmd cp -r "$RESULTS_DIR/nf-covflow/report/"* "$FINAL/" 2>/dev/null || true

# ==========================================================
# STEP 5: STATS + FILTER
# ==========================================================
log "STEP 5 FILTER"

run_cmd python "$SCRIPT_DIR/fasta_stats.py" \
"$FINAL/all_consensus.fasta" \
-o "$FINAL/all_consensus.stats.tsv"

run_cmd python "$SCRIPT_DIR/filter_consensus.py" \
--stats "$FINAL/all_consensus.stats.tsv" \
--fasta "$FINAL/all_consensus.fasta" \
--output "$FINAL/all_consensus.high_quality.fasta" \
--cutoff "$COMPLETENESS_THRESHOLD"

filtered_fasta="$FINAL/all_consensus.high_quality.fasta"

# ==========================================================
# STEP 6: NEXTCLADE
# ==========================================================
log "STEP 6 NEXTCLADE"

nextclade_db="nextstrain/mpox/all-clades"

run_cmd nextclade dataset get \
--name "$nextclade_db" \
--output-dir "$nextclade_db"

run_cmd nextclade run "$filtered_fasta" \
-d "$nextclade_db" \
--output-all "$FINAL/nextclade"

# ==========================================================
# STEP 7: SQUIRREL
# ==========================================================
log "STEP 7 SQUIRREL"

run_cmd squirrel \
-t 8 \
"$filtered_fasta" \
--outdir "$FINAL/squirrel" \
--tempdir "$FINAL/squirrel_tmp" \
--clade split \
--seq-qc \
--run-apobec3-phylo \
--include-background \
--tree-file squirrel_tree



# ==========================================================
# STEP 9: make_summary_report
# ==========================================================
log "=== STEP 9: Making summary report ==="

run_cmd cd "${FINAL}" || error_exit "Failed to cd to summary report dir"

run_cmd python "$SCRIPT_DIR/make_summary_report.py" \
--qc ${QC_FILE} \
--consensus all_consensus.stats.tsv \
--depth chromosome_coverage_depth_summary.tsv \
--nextclade nextclade/nextclade.tsv \
--squirrel squirrel/assignment_report.csv \
--out mpxv_master.tsv

# ==========================================================
# CLEANUP
# ==========================================================

run_cmd rm -rf "$FINAL/squirrel_tmp"

log "DONE"
echo "Pipeline finished successfully"
log "Pipeline version: $VERSION"
log "Results directory: $RESULTS_DIR"
log "Finished at: $(date)"
exit 0
