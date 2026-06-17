#!/usr/bin/env python3
"""
Check exact duplicate opcode sequences inside and across opcode CSV files.

Default usage:
  python dataset/check_opcode_duplicates.py

Custom inputs:
  python dataset/check_opcode_duplicates.py \
    --input train=dataset/opcode_train.csv \
    --input val=dataset/opcode_val.csv \
    --input test=dataset/opcode_test.csv
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INPUTS = (
    "train=dataset/opcode_train.csv",
    "val=dataset/opcode_val.csv",
    "test=dataset/opcode_test.csv",
)


Location = Tuple[str, Path, int, str, str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Report exact duplicate opcode sequences within each CSV and across CSV splits."
    )
    parser.add_argument(
        "--input",
        action="append",
        dest="inputs",
        default=None,
        help=(
            "Input CSV path, optionally named as split=path. Repeat for multiple files. "
            "Default checks train/val/test opcode CSVs."
        ),
    )
    parser.add_argument("--opcode-column", default="opcode", help="Opcode column name.")
    parser.add_argument("--top", type=int, default=5, help="Number of duplicate groups to print per section.")
    parser.add_argument(
        "--report-output",
        default="",
        help="Optional CSV report path for duplicate groups.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with code 1 if any duplicate sequence is found within a file or across files.",
    )
    return parser.parse_args()


def resolve_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def parse_input(value: str) -> Tuple[str, Path]:
    if "=" in value:
        name, raw_path = value.split("=", 1)
        name = name.strip()
        path = resolve_path(raw_path.strip())
        return name or path.stem, path

    path = resolve_path(value)
    return path.stem, path


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


def sequence_hash(sequence: str) -> str:
    return hashlib.sha256(sequence.encode("utf-8")).hexdigest()[:16]


def sequence_prefix(sequence: str, limit: int = 25) -> str:
    if not sequence:
        return "<empty>"
    return " ".join(sequence.split()[:limit])


def location_text(locations: Sequence[Location]) -> str:
    return "; ".join(
        f"{split} row {line_no} id={row_id} file={filename}"
        for split, _path, line_no, row_id, filename in locations
    )


def write_report(path: Path, rows: Sequence[Dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "scope",
        "splits",
        "sequence_hash",
        "count",
        "sequence_token_count",
        "sequence_prefix",
        "locations",
    ]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    args = parse_args()
    input_values = args.inputs or list(DEFAULT_INPUTS)
    inputs = [parse_input(value) for value in input_values]

    per_file_duplicate_groups: Dict[str, List[Tuple[str, int, List[Location]]]] = {}
    all_locations: Dict[str, List[Location]] = defaultdict(list)
    report_rows: List[Dict[str, str]] = []

    try:
        for split_name, path in inputs:
            rows, _fieldnames = read_csv(path, args.opcode_column)
            counts = Counter((row.get(args.opcode_column) or "").strip() for row in rows)
            locations_by_sequence: Dict[str, List[Location]] = defaultdict(list)

            for row_index, row in enumerate(rows, start=2):
                sequence = (row.get(args.opcode_column) or "").strip()
                location: Location = (
                    split_name,
                    path,
                    row_index,
                    str(row.get("id", "")),
                    str(row.get("file", "")),
                )
                locations_by_sequence[sequence].append(location)
                all_locations[sequence].append(location)

            duplicate_groups = [
                (sequence, count, locations_by_sequence[sequence])
                for sequence, count in counts.items()
                if count > 1
            ]
            duplicate_groups.sort(key=lambda item: (-item[1], -len(item[0].split()), sequence_prefix(item[0])))
            per_file_duplicate_groups[split_name] = duplicate_groups

            duplicate_rows_total = sum(count for _sequence, count, _locations in duplicate_groups)
            extra_duplicate_rows = sum(count - 1 for _sequence, count, _locations in duplicate_groups)
            empty_opcode_rows = counts.get("", 0)
            max_group_size = max((count for _sequence, count, _locations in duplicate_groups), default=1)

            print(path.as_posix())
            print(f"  rows: {len(rows)}")
            print(f"  unique_opcode_sequences: {len(counts)}")
            print(f"  duplicate_groups: {len(duplicate_groups)}")
            print(f"  duplicate_rows_total: {duplicate_rows_total}")
            print(f"  extra_duplicate_rows: {extra_duplicate_rows}")
            print(f"  empty_opcode_rows: {empty_opcode_rows}")
            print(f"  max_duplicate_group_size: {max_group_size}")

            if duplicate_groups:
                print("  top_duplicate_groups:")
                for sequence, count, locations in duplicate_groups:
                    report_rows.append(
                        {
                            "scope": "within_file",
                            "splits": split_name,
                            "sequence_hash": sequence_hash(sequence),
                            "count": str(count),
                            "sequence_token_count": str(len(sequence.split())),
                            "sequence_prefix": sequence_prefix(sequence),
                            "locations": location_text(locations),
                        }
                    )
                for index, (sequence, count, locations) in enumerate(duplicate_groups[: args.top], start=1):
                    print(
                        f"    {index}. count={count} tokens={len(sequence.split())} "
                        f"hash={sequence_hash(sequence)} prefix={sequence_prefix(sequence)}"
                    )
                    print(f"       examples={location_text(locations[:10])}")
            else:
                print("  top_duplicate_groups: none")

    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    cross_split_groups: List[Tuple[str, List[Location]]] = []
    for sequence, locations in all_locations.items():
        split_names = {split_name for split_name, _path, _line_no, _row_id, _filename in locations}
        if len(split_names) > 1:
            cross_split_groups.append((sequence, locations))
    cross_split_groups.sort(key=lambda item: (-len(item[1]), -len(item[0].split()), sequence_prefix(item[0])))

    print("CROSS_SPLIT")
    print(f"  duplicate_sequences_across_splits: {len(cross_split_groups)}")
    print(f"  rows_in_cross_split_duplicate_sequences: {sum(len(locations) for _sequence, locations in cross_split_groups)}")
    if cross_split_groups:
        print("  top_cross_split_groups:")
        for sequence, locations in cross_split_groups:
            split_names = sorted({split_name for split_name, _path, _line_no, _row_id, _filename in locations})
            report_rows.append(
                {
                    "scope": "cross_split",
                    "splits": ",".join(split_names),
                    "sequence_hash": sequence_hash(sequence),
                    "count": str(len(locations)),
                    "sequence_token_count": str(len(sequence.split())),
                    "sequence_prefix": sequence_prefix(sequence),
                    "locations": location_text(locations),
                }
            )
        for index, (sequence, locations) in enumerate(cross_split_groups[: args.top], start=1):
            split_names = sorted({split_name for split_name, _path, _line_no, _row_id, _filename in locations})
            print(
                f"    {index}. splits={','.join(split_names)} rows={len(locations)} "
                f"tokens={len(sequence.split())} hash={sequence_hash(sequence)} "
                f"prefix={sequence_prefix(sequence)}"
            )
            print(f"       examples={location_text(locations[:12])}")
    else:
        print("  top_cross_split_groups: none")

    if args.report_output:
        report_path = resolve_path(args.report_output)
        write_report(report_path, report_rows)
        print(f"Report: {report_path}")

    has_duplicates = any(per_file_duplicate_groups.values()) or bool(cross_split_groups)
    if args.strict and has_duplicates:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
