#!/usr/bin/env python3
"""
Append augmented contracts to an opcode train CSV.

The augmented dataset is expected to have this shape:

  F:/RM Datasets/final_augmented_datasets/
    labels/augmented_labels.jsonl
    metadata/<transform>/<augmented-file>.json
    contracts_output/<transform>/<augmented-file>.sol

For each label row, the script tries to read bytecode from the metadata JSON.
If the metadata has no usable bytecode, it compiles the corresponding Solidity
source from contracts_output with Hardhat, reads the produced artifact JSON, and
converts the bytecode into opcode sequence.

Example:
  python dataset/append_augmented_opcode_train.py \
    --base-train-csv dataset/opcode_train.csv \
    --output-train dataset/opcode_train_augmented.csv \
    --strict
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from create_opcode_split_dataset import (
    choose_artifact,
    disassemble_bytecode,
    find_bytecode_in_artifact,
    read_json,
    strip_hex_bytecode,
)


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_AUG_ROOT = Path(r"F:\RM Datasets\final_augmented_datasets")
KNOWN_TRANSFORMS = ("dead_code", "expression", "fhe_swap", "rename")


@dataclass
class AugmentResult:
    row: Dict[str, Any]
    status: str
    source: str
    detail: str
    unknown: List[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read augmented labels/metadata/contracts and append opcode rows to the train CSV."
    )
    parser.add_argument(
        "--aug-root",
        default=str(DEFAULT_AUG_ROOT),
        help="Root folder of augmented dataset. Default: F:/RM Datasets/final_augmented_datasets",
    )
    parser.add_argument(
        "--labels-jsonl",
        default=None,
        help="Augmented labels JSONL. Default: <aug-root>/labels/augmented_labels.jsonl",
    )
    parser.add_argument(
        "--metadata-dir",
        default=None,
        help="Augmented metadata folder. Default: <aug-root>/metadata",
    )
    parser.add_argument(
        "--contracts-output-dir",
        default=None,
        help="Augmented Solidity source folder. Default: <aug-root>/contracts_output",
    )
    parser.add_argument(
        "--base-train-csv",
        default="dataset/opcode_train.csv",
        help="Existing opcode train CSV to append into.",
    )
    parser.add_argument(
        "--output-train",
        default="dataset/opcode_train_augmented.csv",
        help="Output train CSV containing base train rows plus augmented opcode rows.",
    )
    parser.add_argument(
        "--report-output",
        default="dataset/augment_opcode_report.csv",
        help="Status report CSV. Use empty string to disable.",
    )
    parser.add_argument("--file-column", default="file", help="Label column containing augmented .sol filename.")
    parser.add_argument("--opcode-column", default="opcode", help="Output opcode column.")
    parser.add_argument(
        "--prefer-bytecode",
        choices=("deployed", "creation"),
        default="deployed",
        help="Prefer deployed/runtime bytecode or creation bytecode if both exist.",
    )
    parser.add_argument(
        "--include-push-data",
        action="store_true",
        help="Include PUSH operands as 0x... tokens. Default keeps opcode names only.",
    )
    parser.add_argument(
        "--keep-solc-metadata",
        action="store_true",
        help="Do not strip trailing Solidity metadata before disassembly.",
    )
    parser.add_argument(
        "--no-compile-missing",
        action="store_true",
        help="Do not compile source files when metadata bytecode is missing.",
    )
    parser.add_argument(
        "--compile-temp-dir",
        default="contracts/_aug_compile_temp",
        help="Workspace temp source folder used for one-by-one Hardhat compile.",
    )
    parser.add_argument(
        "--hardhat-command",
        default="npx hardhat compile",
        help="Hardhat compile command used for fallback compile.",
    )
    parser.add_argument(
        "--compile-timeout",
        type=int,
        default=1800,
        help="Timeout in seconds for each Hardhat compile command.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Process only the first N augmented rows, useful for smoke tests. 0 means all rows.",
    )
    parser.add_argument(
        "--no-append-base",
        action="store_true",
        help="Write only augmented rows instead of appending them to --base-train-csv.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with non-zero code if any augmented row cannot produce opcode or has unknown opcode bytes.",
    )
    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="Keep compile temp source folder and artifacts for debugging.",
    )
    return parser.parse_args()


def resolve_path(value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def read_csv(path: Path) -> Tuple[List[Dict[str, str]], List[str]]:
    if not path.exists():
        return [], []
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        return [dict(row) for row in reader], list(reader.fieldnames or [])


def write_csv(path: Path, rows: Sequence[Dict[str, Any]], fieldnames: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def read_jsonl(path: Path, limit: int = 0) -> List[Dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(f"Label JSONL tidak ditemukan: {path}")

    rows: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8-sig") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"JSONL invalid di {path}:{line_no}: {exc}") from exc
            if not isinstance(item, dict):
                raise ValueError(f"JSONL row bukan object di {path}:{line_no}")
            rows.append(item)
            if limit and len(rows) >= limit:
                break
    return rows


def infer_transform(filename: str) -> Optional[str]:
    stem = Path(filename).stem
    for transform in KNOWN_TRANSFORMS:
        marker = f"__{transform}_"
        if marker in stem:
            return transform
    return None


def candidate_metadata_paths(metadata_dir: Path, filename: str) -> List[Path]:
    transform = infer_transform(filename)
    stem = Path(filename).stem
    candidates: List[Path] = []
    if transform:
        candidates.append(metadata_dir / transform / f"{stem}.json")
    candidates.append(metadata_dir / f"{stem}.json")
    return candidates


def candidate_source_paths(contracts_output_dir: Path, filename: str) -> List[Path]:
    transform = infer_transform(filename)
    candidates: List[Path] = []
    if transform:
        candidates.append(contracts_output_dir / transform / filename)
    candidates.append(contracts_output_dir / filename)
    return candidates


def find_existing_path(candidates: Iterable[Path]) -> Optional[Path]:
    for path in candidates:
        if path.exists() and path.is_file():
            return path
    return None


def bytecode_from_metadata(metadata_path: Path, prefer_bytecode: str) -> Optional[Tuple[str, str]]:
    try:
        text = metadata_path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = metadata_path.read_text(encoding="utf-8-sig")
    except OSError:
        text = ""

    key_order = (
        ("deployed_bytecode", "deployed_bytecode", 300 if prefer_bytecode == "deployed" else 200),
        ("deployedBytecode", "deployedBytecode", 300 if prefer_bytecode == "deployed" else 200),
        ("runtimeBytecode", "runtimeBytecode", 300 if prefer_bytecode == "deployed" else 200),
        ("runtime_bytecode", "runtime_bytecode", 300 if prefer_bytecode == "deployed" else 200),
        ("bytecode", "bytecode", 200 if prefer_bytecode == "deployed" else 300),
    )
    choices: List[Tuple[str, str, int]] = []
    for key, label, priority in key_order:
        pattern = rf'"{re.escape(key)}"\s*:\s*"(0x[0-9a-fA-F]*)"'
        for match in re.finditer(pattern, text):
            value = match.group(1)
            if strip_hex_bytecode(value):
                choices.append((value, label, priority))
    if choices:
        bytecode, key_path, _priority = max(
            choices,
            key=lambda item: (item[2], len(strip_hex_bytecode(item[0]))),
        )
        return bytecode, key_path

    data = read_json(metadata_path)
    if not data:
        return None
    found = find_bytecode_in_artifact(data, prefer_bytecode)
    if not found:
        return None
    bytecode, key_path, _priority = found
    if not strip_hex_bytecode(bytecode):
        return None
    return bytecode, key_path


def safe_remove_dir(path: Path, allowed_parent: Path) -> None:
    path = path.resolve()
    allowed_parent = allowed_parent.resolve()
    if not path.is_relative_to(allowed_parent):
        raise ValueError(f"Refusing to remove path outside {allowed_parent}: {path}")
    if path.exists():
        shutil.rmtree(path)


def run_hardhat_compile(command: str, batch: str, timeout_seconds: int) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["BATCH"] = batch.replace("\\", "/")
    env["NODE_OPTIONS"] = env.get("NODE_OPTIONS", "--max-old-space-size=4096")
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        shell=True,
        timeout=timeout_seconds,
    )


def compile_source_and_get_bytecode(
    source_path: Path,
    compile_temp_dir: Path,
    hardhat_command: str,
    prefer_bytecode: str,
    compile_timeout: int,
    keep_temp: bool,
) -> Tuple[Optional[str], str]:
    compile_temp_dir = resolve_path(compile_temp_dir)
    temp_parent = (ROOT / "contracts").resolve()
    safe_remove_dir(compile_temp_dir, temp_parent)
    compile_temp_dir.mkdir(parents=True, exist_ok=True)

    target_source = compile_temp_dir / source_path.name
    shutil.copy2(source_path, target_source)

    rel_batch = compile_temp_dir.relative_to(ROOT / "contracts").as_posix()
    artifact_root = ROOT / "artifacts" / "contracts" / rel_batch / source_path.name
    safe_remove_dir(artifact_root, (ROOT / "artifacts" / "contracts").resolve())
    safe_remove_dir(ROOT / "cache", ROOT)

    try:
        result = run_hardhat_compile(hardhat_command, rel_batch, compile_timeout)
    except subprocess.TimeoutExpired:
        return None, f"compile timed out after {compile_timeout} seconds"
    if result.returncode != 0:
        output = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
        return None, f"compile failed: {output[:1200]}"

    choice = choose_artifact(artifact_root, source_path.name, prefer_bytecode)
    if choice is None:
        return None, f"compiled but bytecode artifact not found in {artifact_root}"

    if not keep_temp:
        safe_remove_dir(compile_temp_dir, temp_parent)
        safe_remove_dir(artifact_root, (ROOT / "artifacts" / "contracts").resolve())
        safe_remove_dir(ROOT / "cache", ROOT)

    return choice.bytecode, f"compiled artifact: {choice.path} ({choice.key_path})"


def batch_compile_sources(
    filenames: Sequence[str],
    contracts_output_dir: Path,
    compile_temp_dir: Path,
    hardhat_command: str,
    prefer_bytecode: str,
    compile_timeout: int,
    keep_temp: bool,
) -> Tuple[Dict[str, Tuple[str, str]], Dict[str, str]]:
    compile_temp_dir = resolve_path(compile_temp_dir)
    temp_parent = (ROOT / "contracts").resolve()
    artifacts_parent = (ROOT / "artifacts" / "contracts").resolve()
    rel_batch = compile_temp_dir.relative_to(ROOT / "contracts").as_posix()
    artifact_batch_root = ROOT / "artifacts" / "contracts" / rel_batch

    safe_remove_dir(compile_temp_dir, temp_parent)
    safe_remove_dir(artifact_batch_root, artifacts_parent)
    safe_remove_dir(ROOT / "cache", ROOT)
    compile_temp_dir.mkdir(parents=True, exist_ok=True)

    copied: Dict[str, Path] = {}
    failures: Dict[str, str] = {}
    for filename in filenames:
        source_path = find_existing_path(candidate_source_paths(contracts_output_dir, filename))
        if not source_path:
            failures[filename] = "source not found"
            continue
        target_source = compile_temp_dir / source_path.name
        shutil.copy2(source_path, target_source)
        copied[filename] = source_path

    if not copied:
        return {}, failures

    try:
        result = run_hardhat_compile(hardhat_command, rel_batch, compile_timeout)
    except subprocess.TimeoutExpired:
        detail = f"batch compile timed out after {compile_timeout} seconds"
        for filename in copied:
            failures[filename] = detail
        return {}, failures
    if result.returncode != 0:
        output = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
        detail = f"batch compile failed: {output[:1200]}"
        for filename in copied:
            failures[filename] = detail
        return {}, failures

    compiled: Dict[str, Tuple[str, str]] = {}
    for filename in copied:
        artifact_root = artifact_batch_root / filename
        choice = choose_artifact(artifact_root, filename, prefer_bytecode)
        if choice is None:
            failures[filename] = f"compiled but bytecode artifact not found in {artifact_root}"
            continue
        compiled[filename] = (choice.bytecode, f"compiled artifact: {choice.path} ({choice.key_path})")

    if not keep_temp:
        safe_remove_dir(compile_temp_dir, temp_parent)
        safe_remove_dir(artifact_batch_root, artifacts_parent)
        safe_remove_dir(ROOT / "cache", ROOT)

    return compiled, failures


def opcode_from_bytecode(
    bytecode: str,
    include_push_data: bool,
    keep_solc_metadata: bool,
) -> Tuple[str, List[str]]:
    return disassemble_bytecode(
        bytecode,
        include_push_data=include_push_data,
        keep_solc_metadata=keep_solc_metadata,
    )


def process_augmented_row(
    row: Dict[str, Any],
    metadata_dir: Path,
    contracts_output_dir: Path,
    file_column: str,
    opcode_column: str,
    prefer_bytecode: str,
    include_push_data: bool,
    keep_solc_metadata: bool,
    compile_missing: bool,
    compile_temp_dir: Path,
    hardhat_command: str,
    keep_temp: bool,
) -> AugmentResult:
    output_row = dict(row)
    filename = str(output_row.get(file_column, "")).strip()
    output_row[opcode_column] = ""

    if not filename:
        return AugmentResult(output_row, "missing_file", "", "file column kosong", [])

    metadata_path = find_existing_path(candidate_metadata_paths(metadata_dir, filename))
    bytecode: Optional[str] = None
    source = ""
    detail = ""

    if metadata_path:
        found = bytecode_from_metadata(metadata_path, prefer_bytecode)
        if found:
            bytecode, key_path = found
            source = "metadata"
            detail = f"{metadata_path} ({key_path})"
        else:
            detail = f"metadata without bytecode: {metadata_path}"
    else:
        detail = f"metadata not found for {filename}"

    if bytecode is None and compile_missing:
        source_path = find_existing_path(candidate_source_paths(contracts_output_dir, filename))
        if not source_path:
            return AugmentResult(output_row, "missing_source", "", f"{detail}; source not found", [])
        bytecode, compile_detail = compile_source_and_get_bytecode(
            source_path=source_path,
            compile_temp_dir=compile_temp_dir,
            hardhat_command=hardhat_command,
            prefer_bytecode=prefer_bytecode,
            compile_timeout=1800,
            keep_temp=keep_temp,
        )
        if bytecode:
            source = "compiled"
            detail = compile_detail
        else:
            return AugmentResult(output_row, "compile_failed", "compiled", compile_detail, [])

    if bytecode is None:
        return AugmentResult(output_row, "missing_bytecode", source, detail, [])

    opcode, unknown = opcode_from_bytecode(
        bytecode,
        include_push_data=include_push_data,
        keep_solc_metadata=keep_solc_metadata,
    )
    output_row[opcode_column] = opcode
    if unknown:
        return AugmentResult(output_row, "unknown_opcode", source, detail, unknown)
    if not opcode:
        return AugmentResult(output_row, "empty_opcode", source, detail, [])
    return AugmentResult(output_row, "ok", source, detail, [])


def merged_fieldnames(base_fields: Sequence[str], augment_rows: Sequence[Dict[str, Any]], opcode_column: str) -> List[str]:
    fields: List[str] = []
    for field in base_fields:
        if field and field not in fields and field != opcode_column:
            fields.append(field)

    for row in augment_rows:
        for field in row.keys():
            if field and field not in fields and field != opcode_column:
                fields.append(field)

    if "file" in fields:
        fields.insert(fields.index("file") + 1, opcode_column)
    elif opcode_column not in fields:
        fields.append(opcode_column)
    return fields


def report_rows(results: Sequence[AugmentResult]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for result in results:
        rows.append(
            {
                "id": result.row.get("id", ""),
                "file": result.row.get("file", ""),
                "status": result.status,
                "source": result.source,
                "detail": result.detail,
                "unknown": "; ".join(result.unknown[:20]),
                "opcode_empty": 1 if not result.row.get("opcode") else 0,
            }
        )
    return rows


def status_counts(results: Sequence[AugmentResult]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for result in results:
        counts[result.status] = counts.get(result.status, 0) + 1
    return counts


def source_counts(results: Sequence[AugmentResult]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for result in results:
        key = result.source or "<none>"
        counts[key] = counts.get(key, 0) + 1
    return counts


def print_counts(title: str, counts: Dict[str, int]) -> None:
    print(title)
    for key in sorted(counts):
        print(f"  {key}: {counts[key]}")


def main() -> int:
    args = parse_args()

    aug_root = resolve_path(args.aug_root)
    labels_jsonl = resolve_path(args.labels_jsonl) if args.labels_jsonl else aug_root / "labels" / "augmented_labels.jsonl"
    metadata_dir = resolve_path(args.metadata_dir) if args.metadata_dir else aug_root / "metadata"
    contracts_output_dir = (
        resolve_path(args.contracts_output_dir) if args.contracts_output_dir else aug_root / "contracts_output"
    )
    base_train_csv = resolve_path(args.base_train_csv)
    output_train = resolve_path(args.output_train)
    report_output = resolve_path(args.report_output) if args.report_output else None
    compile_temp_dir = resolve_path(args.compile_temp_dir)

    try:
        base_rows, base_fields = read_csv(base_train_csv)
        label_rows = read_jsonl(labels_jsonl, limit=args.limit)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if args.file_column not in (label_rows[0].keys() if label_rows else []):
        print(f"ERROR: kolom file '{args.file_column}' tidak ada di label JSONL.", file=sys.stderr)
        return 1

    results: List[AugmentResult] = []
    compile_missing = not args.no_compile_missing
    for idx, row in enumerate(label_rows, start=1):
        result = process_augmented_row(
            row=row,
            metadata_dir=metadata_dir,
            contracts_output_dir=contracts_output_dir,
            file_column=args.file_column,
            opcode_column=args.opcode_column,
            prefer_bytecode=args.prefer_bytecode,
            include_push_data=args.include_push_data,
            keep_solc_metadata=args.keep_solc_metadata,
            compile_missing=False,
            compile_temp_dir=compile_temp_dir,
            hardhat_command=args.hardhat_command,
            keep_temp=args.keep_temp,
        )
        results.append(result)
        if idx % 250 == 0:
            print(f"Processed {idx}/{len(label_rows)} augmented rows...", flush=True)

    pending_compile = [
        str(result.row.get(args.file_column, "")).strip()
        for result in results
        if result.status == "missing_bytecode" and str(result.row.get(args.file_column, "")).strip()
    ]
    if compile_missing and pending_compile:
        print(f"Fallback compile untuk {len(pending_compile)} augmented rows tanpa bytecode metadata...", flush=True)
        compiled, compile_failures = batch_compile_sources(
            filenames=pending_compile,
            contracts_output_dir=contracts_output_dir,
            compile_temp_dir=compile_temp_dir,
            hardhat_command=args.hardhat_command,
            prefer_bytecode=args.prefer_bytecode,
            compile_timeout=args.compile_timeout,
            keep_temp=args.keep_temp,
        )
        for idx, result in enumerate(results):
            if result.status != "missing_bytecode":
                continue
            filename = str(result.row.get(args.file_column, "")).strip()
            if filename in compiled:
                bytecode, detail = compiled[filename]
                opcode, unknown = opcode_from_bytecode(
                    bytecode,
                    include_push_data=args.include_push_data,
                    keep_solc_metadata=args.keep_solc_metadata,
                )
                result.row[args.opcode_column] = opcode
                if unknown:
                    results[idx] = AugmentResult(result.row, "unknown_opcode", "compiled", detail, unknown)
                elif opcode:
                    results[idx] = AugmentResult(result.row, "ok", "compiled", detail, [])
                else:
                    results[idx] = AugmentResult(result.row, "empty_opcode", "compiled", detail, [])
            elif filename in compile_failures:
                status = "missing_source" if compile_failures[filename] == "source not found" else "compile_failed"
                results[idx] = AugmentResult(result.row, status, "compiled", compile_failures[filename], [])

    augment_output_rows = [result.row for result in results]
    output_rows: List[Dict[str, Any]] = []
    if not args.no_append_base:
        output_rows.extend(base_rows)
    output_rows.extend(augment_output_rows)

    fieldnames = merged_fieldnames(base_fields, augment_output_rows, args.opcode_column)
    write_csv(output_train, output_rows, fieldnames)

    if report_output:
        write_csv(
            report_output,
            report_rows(results),
            ["id", "file", "status", "source", "detail", "unknown", "opcode_empty"],
        )

    print("Selesai membuat train CSV gabungan dengan data augmentasi.")
    print(f"Base rows      : {len(base_rows) if not args.no_append_base else 0} dari {base_train_csv}")
    print(f"Augment rows   : {len(augment_output_rows)} dari {labels_jsonl}")
    print(f"Total output   : {len(output_rows)} -> {output_train}")
    if report_output:
        print(f"Report         : {report_output}")
    print_counts("Status:", status_counts(results))
    print_counts("Bytecode source:", source_counts(results))

    has_errors = any(result.status != "ok" for result in results)
    if args.strict and has_errors:
        print("ERROR: strict aktif dan masih ada augment row bermasalah.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
