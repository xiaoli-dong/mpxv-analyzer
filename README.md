# 🧬 mpox Analysis Pipeline (Illumina & Nanopore)

An end-to-end **mpox (Monkeypox virus) sequencing analysis pipeline** supporting both:

- 🧪 Illumina (short-read)
- 🔬 Nanopore (long-read)

This pipeline performs QC, consensus generation, coverage analysis, clade assignment, and mutation profiling using integrated Nextflow workflows.

---

## 📌 Overview

The pipeline processes raw sequencing data into:

- Quality-controlled reads
- Consensus genomes
- Coverage statistics
- Clade assignments (Nextclade & Squirrel)
- SNP and mutation annotations
- Final summary report

---

## 🔄 Workflow Diagram

```mermaid
flowchart TD

A[Input Samplesheet] --> B[nf-qcflow (QC)]

B --> C1[Illumina Reads]
B --> C2[Nanopore Reads]

C1 --> D1[ARTIC Illumina Pipeline]
C2 --> D2[Prepare Barcode Structure]
D2 --> D3[ARTIC Nanopore Pipeline]

D1 --> E[Consensus FASTA]
D3 --> E

E --> F[nf-covflow (Coverage)]

F --> G[Summary Report Directory]

G --> H[FASTA Stats]
H --> I[Filter by Completeness]

I --> J[Nextclade]
I --> K[Squirrel]

J --> L[Clade Assignment]
K --> M[Phylogeny + SNP QC]

L --> N[Final Report]
M --> N
