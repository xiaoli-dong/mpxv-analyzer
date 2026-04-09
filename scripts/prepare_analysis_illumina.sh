#!/bin/bash

# Function to display usage instructions
usage() {
  cat <<EOF
Usage: $0 -i <input_directory> -r <run_name> -s <sample_spec> [-o <output_directory>]

This script processes specified sequencing samples from an Illumina run.

Required arguments:
  -i <input_dir>        Illumina sequence run directory (e.g., path/to/Alignment_1)
  -r <run_name>         The name of the run to be processed
  -s <sample_spec>      Sample specification (e.g., "51,56,61" or "5,7,12-18,76")

Optional arguments:
  -o <output_directory> Directory to store processed files (default: ./analysis)

Examples:
  $0 -i /path/to/Alignment_1 -r RUN2023 -s "51,56,61"
  $0 -i /path/to/Alignment_1 -r RUN2023 -s "5-8,12-15" -o /path/to/output
EOF
  exit 1
}

# Function to expand sample ranges
expand_ranges() {
  local ranges=$1
  local result=()
  IFS=',' read -ra parts <<< "$ranges"
  for part in "${parts[@]}"; do
    if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
      for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
        result+=("$i")
      done
    elif [[ $part =~ ^[0-9]+$ ]]; then
      result+=("$part")
    else
      echo "Warning: Ignoring invalid range component '$part'" >&2
    fi
  done
  echo "${result[@]}"
}

# Initialize variables
output_dir="./analysis"
input_dir=""
run=""
sample_spec=""
script_dir=$(realpath "$(dirname "$0")")

# Parse command-line arguments
while getopts ":i:r:s:o:h" opt; do
  case $opt in
    i)
      if ! input_dir=$(realpath "$OPTARG" 2>/dev/null); then
        echo "Error: Invalid input directory: $OPTARG" >&2
        exit 1
      fi
      ;;
    r) run=$OPTARG ;;
    s) sample_spec=$OPTARG ;;
    o)
      if ! output_dir=$(realpath -m "$OPTARG" 2>/dev/null); then
        echo "Error: Invalid output directory: $OPTARG" >&2
        exit 1
      fi
      ;;
    h) usage ;;
    \?) echo "Error: Invalid option -$OPTARG" >&2; usage ;;
    :) echo "Error: Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

# Validate required arguments
if [[ -z "$input_dir" || -z "$run" || -z "$sample_spec" ]]; then
  echo "Error: Missing required argument(s)." >&2
  usage
fi

if [ ! -d "$input_dir" ]; then
  echo "Error: Input directory '$input_dir' does not exist." >&2
  exit 1
fi

# Expand sample list
echo "Expanding sample specification: $sample_spec"
read -ra sample_array <<< "$(expand_ranges "$sample_spec")"
if [ ${#sample_array[@]} -eq 0 ]; then
  echo "Error: No valid samples found after parsing sample specification." >&2
  exit 1
fi

# Create output directories
mkdir -p "$output_dir/raw_data" || { echo "Error: Failed to create raw_data directory"; exit 1; }

# Initialize samplesheet
samplesheet="$output_dir/samplesheet.csv"
echo "sample,fastq_1,fastq_2,long_fastq" > "$samplesheet"

# Main processing loop
for sample_num in "${sample_array[@]}"; do
  echo "Processing sample: $sample_num"
  r1_files=()
  r2_files=()

  tmp_file=$(mktemp) || { echo "Error: Could not create temporary file"; exit 1; }
  find "$input_dir" -type f -name "*_S${sample_num}_*.fastq.gz" > "$tmp_file" 2>/dev/null

  while IFS= read -r file; do
    filename=$(basename "$file")
    if [[ "$filename" =~ _R1_ ]]; then
      r1_files+=("$file")
    elif [[ "$filename" =~ _R2_ ]]; then
      r2_files+=("$file")
    fi
  done < "$tmp_file"
  rm -f "$tmp_file"

  if [[ ${#r1_files[@]} -eq 0 || ${#r2_files[@]} -eq 0 ]]; then
    echo "Warning: Incomplete FASTQ pair for sample $sample_num — skipping." >&2
    continue
  fi

  # Sort and select
  IFS=$'\n' sorted_r1=($(sort -V <<<"${r1_files[*]}"))
  IFS=$'\n' sorted_r2=($(sort -V <<<"${r2_files[*]}"))
  r1_file="${sorted_r1[0]}"
  r2_file="${sorted_r2[0]}"
  r1_basename=$(basename "$r1_file")
  r2_basename=$(basename "$r2_file")


  cp "$r1_file" "$output_dir/raw_data/${run}-${r1_basename}" || { echo "Error copying $r1_file to raw_data"; continue; }
  cp "$r2_file" "$output_dir/raw_data/${run}-${r2_basename}" || { echo "Error copying $r2_file to raw_data"; continue; }

  echo "${run}-S${sample_num},./raw_data/${run}-${r1_basename},./raw_data/${run}-${r2_basename},NA" >> "$samplesheet"
done

# Copy any .config files from script directory to output_dir
echo "Copying .config files from conf directory to output directory..."
config_files=("$script_dir"/../conf/*.config)
if ls "$script_dir/../conf/"*.config >/dev/null 2>&1; then
  cp "$script_dir/../conf/"*.config "$output_dir/" || { echo "Warning: Failed to copy one or more .config files." >&2; }
  echo "✅ Config files copied to: $output_dir"
else
  echo "ℹ️  No .config files found in $script_dir — skipping copy."
fi

echo "✅ Processing complete."
echo "🗂️  Output directory: $output_dir"
echo "📄 Samplesheet: $samplesheet"
