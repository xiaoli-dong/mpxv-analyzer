#!/usr/bin/env python3

import argparse
import csv
from Bio import SeqIO
import sys
import os


def parse_args():
    parser = argparse.ArgumentParser(
        description="Filter FASTA sequences using completeness from stats.tsv"
    )
    parser.add_argument("--stats", required=True, help="Path to stats TSV file")
    parser.add_argument("--fasta", required=True, help="Path to input FASTA file")
    parser.add_argument("--output", required=True, help="Output filtered FASTA")
    parser.add_argument("--cutoff", type=float, default=0.8,
                        help="Completeness threshold (default: 0.8)")
    parser.add_argument("--id_out", help="Optional output file for selected IDs")
    return parser.parse_args()


def load_high_quality_ids(stats_file, cutoff):
    """Read stats.tsv and return IDs passing completeness cutoff"""
    ids = set()
    total = 0

    with open(stats_file) as f:
        reader = csv.DictReader(f, delimiter="\t")

        # Validate required columns
        required_cols = {"#id", "completeness"}
        if not required_cols.issubset(reader.fieldnames):
            raise ValueError(f"Missing required columns in stats file: {required_cols}")

        for row in reader:
            total += 1
            try:
                completeness = float(row["completeness"])
                if completeness >= cutoff:
                    ids.add(row["#id"])
            except Exception as e:
                print(f"[WARN] Skipping row: {row} ({e})", file=sys.stderr)

    return ids, total


def filter_fasta(input_fasta, output_fasta, valid_ids):
    """Filter FASTA based on valid IDs"""
    count_in = 0
    count_out = 0

    with open(output_fasta, "w") as out_handle:
        for record in SeqIO.parse(input_fasta, "fasta"):
            count_in += 1


            # Match only the first token in header
            seq_id = record.id

            if seq_id in valid_ids:
                # ✅ CLEAN HEADER
                record.id = seq_id
                record.description = seq_id

                SeqIO.write(record, out_handle, "fasta")
                count_out += 1

    return count_in, count_out


def write_ids(id_file, ids):
    """Write selected IDs to file"""
    with open(id_file, "w") as f:
        for sid in sorted(ids):
            f.write(sid + "\n")


def main():
    args = parse_args()

    # Input validation
    if not os.path.exists(args.stats):
        sys.exit(f"[ERROR] Stats file not found: {args.stats}")

    if not os.path.exists(args.fasta):
        sys.exit(f"[ERROR] FASTA file not found: {args.fasta}")

    print(f"[INFO] Completeness cutoff: {args.cutoff}")

    # Step 1: load IDs
    ids, total = load_high_quality_ids(args.stats, args.cutoff)

    print(f"[INFO] {len(ids)} / {total} samples passed filter")

    if not ids:
        print("[WARNING] No sequences passed the threshold", file=sys.stderr)

    # Step 2: filter FASTA
    total_seqs, kept_seqs = filter_fasta(args.fasta, args.output, ids)

    print(f"[INFO] FASTA sequences: {total_seqs}")
    print(f"[INFO] Kept sequences: {kept_seqs}")
    print(f"[INFO] Output written to: {args.output}")

    # Step 3: optional ID list
    if args.id_out:
        write_ids(args.id_out, ids)
        print(f"[INFO] ID list written to: {args.id_out}")


if __name__ == "__main__":
    main()
