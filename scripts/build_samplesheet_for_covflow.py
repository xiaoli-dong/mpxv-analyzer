#!/usr/bin/env python3
import os
import csv
import argparse
from collections import defaultdict

def main():
    parser = argparse.ArgumentParser(description="Create a sample sheet from BAM files.")
    parser.add_argument("-i", "--input_dir", required=True, help="Directory with BAM files")
    parser.add_argument("-o", "--output", default="samplesheet.csv", help="Output CSV file")
    parser.add_argument("--ref_fasta", required=True, help="Reference FASTA file")
    parser.add_argument("--bed_file", required=True, help="BED file")
    parser.add_argument("--delimiter", default=".", help="Delimiter to split sample name from BAM filename")
    args = parser.parse_args()

    # List all BAM files
    bam_files = sorted(f for f in os.listdir(args.input_dir) if f.endswith(".bam"))
    if not bam_files:
        print(f"No BAM files found in {args.input_dir}")
        return

    # Group BAM files by sample
    samples = defaultdict(list)
    for bam in bam_files:
        # Extract sample name: first part before delimiter (.)
        sample = bam.split(args.delimiter)[0]
        bam_path = os.path.join(args.input_dir, bam)
        samples[sample].append(bam_path)

    # Write sample sheet
    with open(args.output, "w", newline="") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["sample", "bam", "ref_fasta", "bed_file"])
        for sample, bams in sorted(samples.items()):
            # Join multiple BAMs with comma
            bam_list = ",".join(bams)
            writer.writerow([sample, bam_list, args.ref_fasta, args.bed_file])

    print(f"Sample sheet written to: {args.output}")


if __name__ == "__main__":
    main()
