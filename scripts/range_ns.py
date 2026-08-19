import argparse

parser = argparse.ArgumentParser()
parser.add_argument("-i", "--input", required=True, help="Input FASTA")
args = parser.parse_args()


def read_fasta(filename):
    header = None
    seq = []

    with open(filename) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith(">"):
                if header is not None:
                    yield header, "".join(seq)
                header = line[1:].split()[0]
                seq = []
            else:
                seq.append(line)
        if header is not None:
            yield header, "".join(seq)


def find_n_ranges(seq):
    """Return list of (start, end) positions (1-based) for consecutive N blocks."""
    ranges = []
    in_block = False

    for i, base in enumerate(seq, start=1):
        if base == "N":
            if not in_block:
                start = i
                in_block = True
        else:
            if in_block:
                ranges.append((start, i - 1))
                in_block = False

    if in_block:
        ranges.append((start, len(seq)))

    return ranges


print("Sequence\tLength\tFirst_N\tN_ranges")

for seq_id, seq in read_fasta(args.input):
    seq = seq.upper()
    length = len(seq)
    first_n = seq.find("N")
    first_n = first_n + 1 if first_n != -1 else "No N"

    ranges = find_n_ranges(seq)
    range_str = ", ".join(f"{s}-{e}" for s, e in ranges) if ranges else "None"

    print(f"{seq_id}\t{length}\t{first_n}\t{range_str}")
