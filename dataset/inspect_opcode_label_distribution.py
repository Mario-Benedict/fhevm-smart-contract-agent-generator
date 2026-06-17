#!/usr/bin/env python3
"""
Audit opcode content and print label-combination distribution for a CSV dataset.

Default target:
  dataset/opcode_train_augmented.csv

Example:
  python dataset/inspect_opcode_label_distribution.py --strict
"""

from __future__ import annotations

import argparse
import csv
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


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
    parser = argparse.ArgumentParser(
        description="Verify opcode rows and print label-combination distribution."
    )
    parser.add_argument(
        "--input",
        default="dataset/opcode_train_augmented.csv",
        help="Input CSV with opcode and label columns.",
    )
    parser.add_argument("--opcode-column", default="opcode", help="Opcode column name.")
    parser.add_argument(
        "--label-columns",
        default="",
        help="Comma-separated label columns. If omitted, binary 0/1 columns are inferred.",
    )
    parser.add_argument(
        "--distribution-output",
        default="dataset/train_augmented_label_distribution.csv",
        help="Optional CSV output for label-combination distribution. Use empty string to disable.",
    )
    parser.add_argument(
        "--per-class-output",
        default="dataset/train_augmented_per_class_distribution.csv",
        help="Optional CSV output for per-class positive/negative distribution. Use empty string to disable.",
    )
    parser.add_argument(
        "--positive-count-output",
        default="dataset/train_augmented_positive_count_distribution.csv",
        help="Optional CSV output for count of positive labels per row. Use empty string to disable.",
    )
    parser.add_argument(
        "--print-output",
        default="",
        help="Optional human-readable TXT report output.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with error if opcode is empty or any inferred label is not binary.",
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


def percentile(sorted_values: Sequence[int], pct: float) -> int:
    if not sorted_values:
        return 0
    if len(sorted_values) == 1:
        return sorted_values[0]
    index = round((len(sorted_values) - 1) * pct)
    return sorted_values[index]


def label_tuple(row: Dict[str, str], labels: Sequence[str]) -> Tuple[int, ...]:
    return tuple(int(str(row.get(label, "0")).strip()) for label in labels)


def combination_text(combo: Sequence[int], labels: Sequence[str]) -> str:
    return "|".join(f"{label}={value}" for label, value in zip(labels, combo))


def write_distribution(
    path: Path,
    combo_counts: Counter[Tuple[int, ...]],
    labels: Sequence[str],
    total: int,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = ["combination", "bitstring", "count", "percent", *labels]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for combo, count in combo_counts.most_common():
            row: Dict[str, Any] = {
                "combination": combination_text(combo, labels),
                "bitstring": "".join(str(value) for value in combo),
                "count": count,
                "percent": f"{(count / total * 100):.4f}" if total else "0.0000",
            }
            row.update({label: value for label, value in zip(labels, combo)})
            writer.writerow(row)


def write_per_class_distribution(
    path: Path,
    labels: Sequence[str],
    per_label_positive: Counter[str],
    total: int,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = ["label", "positive", "negative", "positive_percent", "negative_percent"]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for label in labels:
            positive = per_label_positive[label]
            negative = total - positive
            writer.writerow(
                {
                    "label": label,
                    "positive": positive,
                    "negative": negative,
                    "positive_percent": f"{(positive / total * 100):.4f}" if total else "0.0000",
                    "negative_percent": f"{(negative / total * 100):.4f}" if total else "0.0000",
                }
            )


def write_positive_count_distribution(
    path: Path,
    positive_counts: Counter[int],
    total: int,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = ["positive_label_count", "rows", "percent"]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for count in sorted(positive_counts):
            rows = positive_counts[count]
            writer.writerow(
                {
                    "positive_label_count": count,
                    "rows": rows,
                    "percent": f"{(rows / total * 100):.4f}" if total else "0.0000",
                }
            )


def build_printable_report(
    rows: Sequence[Dict[str, str]],
    labels: Sequence[str],
    opcode_column: str,
    token_counts: Sequence[int],
    empty_rows: Sequence[int],
    combo_counts: Counter[Tuple[int, ...]],
    positive_counts: Counter[int],
    per_label_positive: Counter[str],
    input_path: Path,
    distribution_output: Optional[Path],
    per_class_output: Optional[Path],
    positive_count_output: Optional[Path],
) -> List[str]:
    total = len(rows)
    sorted_counts = sorted(token_counts)
    average = sum(token_counts) / total if total else 0
    median = percentile(sorted_counts, 0.50)

    lines: List[str] = []
    lines.append("Dataset opcode + label distribution")
    lines.append("=" * 40)
    lines.append(f"Input file        : {input_path}")
    lines.append(f"Input rows        : {total}")
    lines.append(f"Opcode column     : {opcode_column}")
    lines.append(f"Label columns     : {', '.join(labels)}")
    lines.append(f"Empty opcode rows : {len(empty_rows)}")
    lines.append(
        "Opcode tokens     : "
        f"min={min(sorted_counts) if sorted_counts else 0}, "
        f"p05={percentile(sorted_counts, 0.05)}, "
        f"median={median}, "
        f"mean={average:.2f}, "
        f"p95={percentile(sorted_counts, 0.95)}, "
        f"max={max(sorted_counts) if sorted_counts else 0}"
    )

    lines.append("")
    lines.append("Per-label positives")
    lines.append("-" * 40)
    for label in labels:
        count = per_label_positive[label]
        pct = count / total * 100 if total else 0
        lines.append(f"{label}: {count} ({pct:.2f}%)")

    lines.append("")
    lines.append("Positive-label count per row")
    lines.append("-" * 40)
    for count in sorted(positive_counts):
        pct = positive_counts[count] / total * 100 if total else 0
        lines.append(f"{count} positive labels: {positive_counts[count]} ({pct:.2f}%)")

    lines.append("")
    lines.append("Label-combination distribution")
    lines.append("-" * 40)
    for combo, count in combo_counts.most_common():
        pct = count / total * 100 if total else 0
        bitstring = "".join(str(value) for value in combo)
        lines.append(f"{bitstring} | {combination_text(combo, labels)}: {count} ({pct:.2f}%)")

    if distribution_output:
        lines.append("")
        lines.append(f"Distribution CSV  : {distribution_output}")
    if per_class_output:
        lines.append(f"Per-class CSV     : {per_class_output}")
    if positive_count_output:
        lines.append(f"Positive count CSV: {positive_count_output}")

    if empty_rows[:10]:
        lines.append("")
        lines.append(f"Empty opcode line examples: {', '.join(map(str, empty_rows[:10]))}")

    return lines


def main() -> int:
    args = parse_args()
    input_path = resolve_path(args.input)
    distribution_output = resolve_path(args.distribution_output) if args.distribution_output else None
    per_class_output = resolve_path(args.per_class_output) if args.per_class_output else None
    positive_count_output = resolve_path(args.positive_count_output) if args.positive_count_output else None
    print_output = resolve_path(args.print_output) if args.print_output else None

    try:
        rows, fieldnames = read_csv(input_path)
        if args.opcode_column not in fieldnames:
            raise ValueError(f"Kolom opcode '{args.opcode_column}' tidak ada.")
        labels = parse_label_columns(args.label_columns, fieldnames, rows)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    token_counts = [len(str(row.get(args.opcode_column, "")).split()) for row in rows]
    empty_rows = [idx for idx, count in enumerate(token_counts, start=2) if count == 0]
    sorted_counts = sorted(token_counts)

    invalid_label_rows: List[str] = []
    combo_counts: Counter[Tuple[int, ...]] = Counter()
    positive_counts: Counter[int] = Counter()
    per_label_positive: Counter[str] = Counter()
    for line_no, row in enumerate(rows, start=2):
        try:
            combo = label_tuple(row, labels)
        except ValueError:
            invalid_label_rows.append(f"line {line_no}")
            continue
        combo_counts[combo] += 1
        positive_counts[sum(combo)] += 1
        for label, value in zip(labels, combo):
            if value == 1:
                per_label_positive[label] += 1

    total = len(rows)
    report_lines = build_printable_report(
        rows=rows,
        labels=labels,
        opcode_column=args.opcode_column,
        token_counts=token_counts,
        empty_rows=empty_rows,
        combo_counts=combo_counts,
        positive_counts=positive_counts,
        per_label_positive=per_label_positive,
        input_path=input_path,
        distribution_output=distribution_output,
        per_class_output=per_class_output,
        positive_count_output=positive_count_output,
    )
    print("\n".join(report_lines))

    if distribution_output:
        write_distribution(distribution_output, combo_counts, labels, total)
    if per_class_output:
        write_per_class_distribution(per_class_output, labels, per_label_positive, total)
    if positive_count_output:
        write_positive_count_distribution(positive_count_output, positive_counts, total)
    if print_output:
        print_output.parent.mkdir(parents=True, exist_ok=True)
        print_output.write_text("\n".join(report_lines) + "\n", encoding="utf-8")
        print(f"\nPrintable report  : {print_output}")

    if empty_rows[:10]:
        print(f"\nEmpty opcode line examples: {', '.join(map(str, empty_rows[:10]))}", file=sys.stderr)
    if invalid_label_rows[:10]:
        print(f"Invalid label row examples: {', '.join(invalid_label_rows[:10])}", file=sys.stderr)

    if args.strict and (empty_rows or invalid_label_rows):
        print("ERROR: strict aktif dan dataset belum bersih.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
