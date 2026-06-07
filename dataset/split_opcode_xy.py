#!/usr/bin/env python3
"""
Split an opcode dataset CSV into X and Y CSV files.

X contains only the opcode sequence.
Y contains only the label columns by default.

Default target:
  dataset/opcode_train_augmented.csv

Example:
  python dataset/split_opcode_xy.py
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_EXCLUDED_COLUMNS = {
    "id",
    "file",
    "opcode",
    "bytecode",
    "source",
    "status",
    "detail",
    "unknown",
    "opcode_empty",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create X/Y CSVs from an opcode dataset CSV.")
    parser.add_argument(
        "--input",
        default="dataset/opcode_train_augmented.csv",
        help="Input CSV with opcode and label columns.",
    )
    parser.add_argument(
        "--x-output",
        default="dataset/x_train_augmented.csv",
        help="Output X CSV. Contains opcode only by default.",
    )
    parser.add_argument(
        "--y-output",
        default="dataset/y_train_augmented.csv",
        help="Output Y CSV. Contains label columns and label_combination.",
    )
    parser.add_argument("--opcode-column", default="opcode", help="Opcode column name.")
    parser.add_argument(
        "--label-columns",
        default="",
        help="Comma-separated label columns. If omitted, binary 0/1 columns are inferred.",
    )
    parser.add_argument(
        "--include-id",
        action="store_true",
        help="Include id/file columns in both X and Y for row tracing.",
    )
    parser.add_argument(
        "--include-combination",
        action="store_true",
        help="Add a label_combination bitstring column to Y.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with error if opcode is empty or any label value is not 0/1.",
    )
    return parser.parse_args()


def resolve_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def read_csv(path: Path) -> Tuple[List[Dict[str, str]], List[str]]:
    if not path.exists():
        raise FileNotFoundError(f"CSV tidak ditemukan: {path}")
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        rows = [dict(row) for row in reader]
        fieldnames = list(reader.fieldnames or [])
    if not fieldnames:
        raise ValueError(f"Header CSV tidak terbaca: {path}")
    return rows, fieldnames


def write_csv(path: Path, rows: Sequence[Dict[str, str]], fieldnames: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def parse_label_columns(raw: str, fieldnames: Sequence[str], rows: Sequence[Dict[str, str]]) -> List[str]:
    if raw.strip():
        labels = [item.strip() for item in raw.split(",") if item.strip()]
        missing = [label for label in labels if label not in fieldnames]
        if missing:
            raise ValueError(f"Kolom label tidak ditemukan: {', '.join(missing)}")
        return labels

    labels: List[str] = []
    for field in fieldnames:
        if field in DEFAULT_EXCLUDED_COLUMNS:
            continue
        values = [str(row.get(field, "")).strip() for row in rows]
        non_empty = [value for value in values if value != ""]
        if non_empty and all(value in {"0", "1"} for value in non_empty):
            labels.append(field)
    if not labels:
        raise ValueError("Tidak ada kolom label biner 0/1 yang bisa diinfer.")
    return labels


def label_bitstring(row: Dict[str, str], labels: Sequence[str]) -> str:
    values: List[str] = []
    for label in labels:
        value = str(row.get(label, "")).strip()
        if value not in {"0", "1"}:
            raise ValueError(f"label {label} bernilai bukan 0/1: {value!r}")
        values.append(value)
    return "".join(values)


def main() -> int:
    args = parse_args()
    input_path = resolve_path(args.input)
    x_output = resolve_path(args.x_output)
    y_output = resolve_path(args.y_output)

    try:
        rows, fieldnames = read_csv(input_path)
        if args.opcode_column not in fieldnames:
            raise ValueError(f"Kolom opcode '{args.opcode_column}' tidak ada.")
        labels = parse_label_columns(args.label_columns, fieldnames, rows)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    x_rows: List[Dict[str, str]] = []
    y_rows: List[Dict[str, str]] = []
    empty_opcode_lines: List[int] = []
    invalid_label_lines: List[str] = []

    trace_fields = [field for field in ("id", "file") if field in fieldnames] if args.include_id else []
    for line_no, row in enumerate(rows, start=2):
        opcode = str(row.get(args.opcode_column, "")).strip()
        if not opcode:
            empty_opcode_lines.append(line_no)

        x_row = {field: row.get(field, "") for field in trace_fields}
        x_row[args.opcode_column] = opcode
        x_rows.append(x_row)

        try:
            combination = label_bitstring(row, labels)
        except ValueError as exc:
            invalid_label_lines.append(f"line {line_no}: {exc}")
            combination = ""

        y_row = {field: row.get(field, "") for field in trace_fields}
        y_row.update({label: str(row.get(label, "")).strip() for label in labels})
        if args.include_combination:
            y_row["label_combination"] = combination
        y_rows.append(y_row)

    x_fields = [*trace_fields, args.opcode_column]
    y_fields = [*trace_fields, *labels]
    if args.include_combination:
        y_fields.append("label_combination")
    write_csv(x_output, x_rows, x_fields)
    write_csv(y_output, y_rows, y_fields)

    print("Selesai split dataset opcode menjadi X/Y CSV.")
    print(f"Input rows   : {len(rows)} dari {input_path}")
    print(f"X output     : {x_output}")
    print(f"Y output     : {y_output}")
    print(f"X columns    : {', '.join(x_fields)}")
    print(f"Y labels     : {', '.join(labels)}")
    print(f"Empty opcode : {len(empty_opcode_lines)}")

    if empty_opcode_lines[:10]:
        print(f"Empty opcode line examples: {', '.join(map(str, empty_opcode_lines[:10]))}", file=sys.stderr)
    if invalid_label_lines[:10]:
        print(f"Invalid label row examples: {', '.join(invalid_label_lines[:10])}", file=sys.stderr)

    if args.strict and (empty_opcode_lines or invalid_label_lines):
        print("ERROR: strict aktif dan X/Y belum bersih.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
