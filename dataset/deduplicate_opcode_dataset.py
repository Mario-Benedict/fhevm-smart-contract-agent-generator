#!/usr/bin/env python3
"""
Deduplicate an opcode dataset by exact opcode sequence.

The first row for each opcode sequence is kept. This is useful for augmented
datasets where multiple source variants compile to identical deployed runtime
bytecode and therefore identical opcode sequences.

Example:
  python dataset/deduplicate_opcode_dataset.py \
    --input dataset/opcode_train_augmented.csv \
    --output dataset/opcode_train_augmented.csv \
    --report-output dataset/opcode_train_augmented_dedup_report.csv \
    --strict
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


ROOT = Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Deduplicate CSV rows by exact opcode sequence.")
    parser.add_argument(
        "--input",
        default="dataset/opcode_train_augmented.csv",
        help="Input CSV containing an opcode column.",
    )
    parser.add_argument(
        "--output",
        default="dataset/opcode_train_augmented_dedup.csv",
        help="Output deduplicated CSV. May be the same path as --input.",
    )
    parser.add_argument("--opcode-column", default="opcode", help="Opcode column name.")
    parser.add_argument(
        "--report-output",
        default="",
        help="Optional CSV report of dropped duplicate rows.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with error if any row has an empty opcode sequence.",
    )
    return parser.parse_args()


def resolve_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def read_csv(path: Path, opcode_column: str) -> Tuple[List[Dict[str, str]], List[str]]:
    if not path.exists():
        raise FileNotFoundError(f"CSV tidak ditemukan: {path}")

    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        rows = [dict(row) for row in reader]
        fieldnames = list(reader.fieldnames or [])

    if not fieldnames:
        raise ValueError(f"CSV kosong atau header tidak terbaca: {path}")
    if opcode_column not in fieldnames:
        raise ValueError(f"Kolom opcode '{opcode_column}' tidak ada di {path}")
    return rows, fieldnames


def write_csv(path: Path, rows: Sequence[Dict[str, str]], fieldnames: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def sequence_hash(sequence: str) -> str:
    return hashlib.sha256(sequence.encode("utf-8")).hexdigest()[:16]


def main() -> int:
    args = parse_args()
    input_path = resolve_path(args.input)
    output_path = resolve_path(args.output)
    report_path = resolve_path(args.report_output) if args.report_output else None

    try:
        rows, fieldnames = read_csv(input_path, args.opcode_column)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    seen: Dict[str, Dict[str, str]] = {}
    kept_rows: List[Dict[str, str]] = []
    dropped_rows: List[Dict[str, str]] = []
    empty_opcode_lines: List[int] = []

    for line_no, row in enumerate(rows, start=2):
        sequence = str(row.get(args.opcode_column, "")).strip()
        if not sequence:
            empty_opcode_lines.append(line_no)

        if sequence not in seen:
            seen[sequence] = row
            kept_rows.append(row)
            continue

        first = seen[sequence]
        dropped_rows.append(
            {
                "dropped_line": str(line_no),
                "dropped_id": str(row.get("id", "")),
                "dropped_file": str(row.get("file", "")),
                "kept_id": str(first.get("id", "")),
                "kept_file": str(first.get("file", "")),
                "sequence_hash": sequence_hash(sequence),
                "sequence_token_count": str(len(sequence.split())),
            }
        )

    write_csv(output_path, kept_rows, fieldnames)
    if report_path:
        write_csv(
            report_path,
            dropped_rows,
            [
                "dropped_line",
                "dropped_id",
                "dropped_file",
                "kept_id",
                "kept_file",
                "sequence_hash",
                "sequence_token_count",
            ],
        )

    print("Selesai deduplicate opcode dataset.")
    print(f"Input rows       : {len(rows)} dari {input_path}")
    print(f"Output rows      : {len(kept_rows)} -> {output_path}")
    print(f"Dropped rows     : {len(dropped_rows)}")
    print(f"Unique sequences : {len(seen)}")
    print(f"Empty opcode     : {len(empty_opcode_lines)}")
    if report_path:
        print(f"Report           : {report_path}")

    if empty_opcode_lines[:10]:
        print(f"Empty opcode line examples: {', '.join(map(str, empty_opcode_lines[:10]))}", file=sys.stderr)
    if args.strict and empty_opcode_lines:
        print("ERROR: strict aktif dan masih ada opcode kosong.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
