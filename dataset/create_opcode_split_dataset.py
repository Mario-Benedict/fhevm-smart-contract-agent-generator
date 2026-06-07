#!/usr/bin/env python3
"""
Create train/test CSV files with an added EVM opcode column.

The input split CSVs are expected to contain at least a `file` column, e.g.:
  id,file,acl_misconfig,arithmetic_overflow_underflow,callback_replay

For each row, this script looks under:
  <artifacts-dir>/<file>/

It scans only artifact JSON files, skipping `build-info/` and `*.dbg.json`, then
chooses the JSON that contains real non-empty bytecode. The bytecode is
converted into an opcode sequence and written to a new CSV.

Example:
  python dataset/create_opcode_split_dataset.py \
    --train-split dataset/split/train.csv \
    --test-split dataset/split/test.csv \
    --artifacts-dir output/contracts \
    --output-train dataset/opcode_train.csv \
    --output-test dataset/opcode_test.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


ROOT = Path(__file__).resolve().parent.parent

BYTECODE_PATHS = [
    ("deployedBytecode",),
    ("deployed_bytecode",),
    ("runtimeBytecode",),
    ("runtime_bytecode",),
    ("evm", "deployedBytecode", "object"),
    ("evm", "deployed_bytecode", "object"),
    ("bytecode",),
    ("evm", "bytecode", "object"),
    ("object",),
]

DEFAULT_SKIP_DIR_NAMES = {"build-info", "build_info"}

# Current EVM opcode table through Cancun/Prague-era additions commonly emitted
# by solc 0.8.24+ with evmVersion=cancun.
OPCODES: Dict[int, str] = {
    0x00: "STOP",
    0x01: "ADD",
    0x02: "MUL",
    0x03: "SUB",
    0x04: "DIV",
    0x05: "SDIV",
    0x06: "MOD",
    0x07: "SMOD",
    0x08: "ADDMOD",
    0x09: "MULMOD",
    0x0A: "EXP",
    0x0B: "SIGNEXTEND",
    0x10: "LT",
    0x11: "GT",
    0x12: "SLT",
    0x13: "SGT",
    0x14: "EQ",
    0x15: "ISZERO",
    0x16: "AND",
    0x17: "OR",
    0x18: "XOR",
    0x19: "NOT",
    0x1A: "BYTE",
    0x1B: "SHL",
    0x1C: "SHR",
    0x1D: "SAR",
    0x20: "SHA3",
    0x30: "ADDRESS",
    0x31: "BALANCE",
    0x32: "ORIGIN",
    0x33: "CALLER",
    0x34: "CALLVALUE",
    0x35: "CALLDATALOAD",
    0x36: "CALLDATASIZE",
    0x37: "CALLDATACOPY",
    0x38: "CODESIZE",
    0x39: "CODECOPY",
    0x3A: "GASPRICE",
    0x3B: "EXTCODESIZE",
    0x3C: "EXTCODECOPY",
    0x3D: "RETURNDATASIZE",
    0x3E: "RETURNDATACOPY",
    0x3F: "EXTCODEHASH",
    0x40: "BLOCKHASH",
    0x41: "COINBASE",
    0x42: "TIMESTAMP",
    0x43: "NUMBER",
    0x44: "PREVRANDAO",
    0x45: "GASLIMIT",
    0x46: "CHAINID",
    0x47: "SELFBALANCE",
    0x48: "BASEFEE",
    0x49: "BLOBHASH",
    0x4A: "BLOBBASEFEE",
    0x50: "POP",
    0x51: "MLOAD",
    0x52: "MSTORE",
    0x53: "MSTORE8",
    0x54: "SLOAD",
    0x55: "SSTORE",
    0x56: "JUMP",
    0x57: "JUMPI",
    0x58: "PC",
    0x59: "MSIZE",
    0x5A: "GAS",
    0x5B: "JUMPDEST",
    0x5C: "TLOAD",
    0x5D: "TSTORE",
    0x5E: "MCOPY",
    0x5F: "PUSH0",
    0xA0: "LOG0",
    0xA1: "LOG1",
    0xA2: "LOG2",
    0xA3: "LOG3",
    0xA4: "LOG4",
    0xF0: "CREATE",
    0xF1: "CALL",
    0xF2: "CALLCODE",
    0xF3: "RETURN",
    0xF4: "DELEGATECALL",
    0xF5: "CREATE2",
    0xFA: "STATICCALL",
    0xFD: "REVERT",
    0xFE: "INVALID",
    0xFF: "SELFDESTRUCT",
}

for value in range(0x60, 0x80):
    OPCODES[value] = f"PUSH{value - 0x5F}"
for value in range(0x80, 0x90):
    OPCODES[value] = f"DUP{value - 0x7F}"
for value in range(0x90, 0xA0):
    OPCODES[value] = f"SWAP{value - 0x8F}"


SOLC_METADATA_MARKERS = (
    "a264697066735822",      # ipfs
    "a265627a7a72305820",    # bzzr0
    "a264627a7a72315820",    # bzzr1
    "a165627a7a72305820",    # older bzzr0
    "a164736f6c6343",        # solc-only metadata map
)


@dataclass
class ArtifactChoice:
    path: Path
    bytecode: str
    key_path: str
    priority: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read train/test split CSVs and add an opcode column from compiled artifact bytecode."
    )
    parser.add_argument("--train-split", required=True, help="Input train split CSV.")
    parser.add_argument("--test-split", required=True, help="Input test split CSV.")
    parser.add_argument("--artifacts-dir", required=True, help="Artifact root, e.g. output/contracts.")
    parser.add_argument("--output-train", required=True, help="Output train CSV with opcode column.")
    parser.add_argument("--output-test", required=True, help="Output test CSV with opcode column.")
    parser.add_argument("--file-column", default="file", help="Column containing contract .sol filename.")
    parser.add_argument("--opcode-column", default="opcode", help="Output opcode column name.")
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
        help="Do not strip trailing Solidity CBOR metadata before disassembly.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with error if a row cannot produce opcode or contains unknown opcode bytes.",
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
        raise ValueError(f"CSV kosong atau header tidak terbaca: {path}")
    return rows, fieldnames


def write_csv(path: Path, rows: Sequence[Dict[str, Any]], fieldnames: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def read_json(path: Path) -> Optional[Dict[str, Any]]:
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def get_nested(data: Dict[str, Any], keys: Sequence[str]) -> Any:
    value: Any = data
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def bytecode_from_value(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and isinstance(value.get("object"), str):
        return str(value["object"])
    return ""


def strip_hex_bytecode(value: Any) -> str:
    text = str(value or "").strip()
    if not text or text.lower() == "0x":
        return ""
    if text.lower().startswith("0x"):
        text = text[2:]
    compact = "".join(text.split())
    if not compact or len(compact) % 2 != 0:
        return ""
    if any(ch not in "0123456789abcdefABCDEF" for ch in compact):
        return ""
    return compact.lower()


def strip_solc_metadata(compact_hex: str) -> str:
    marker_positions = [
        compact_hex.find(marker)
        for marker in SOLC_METADATA_MARKERS
        if compact_hex.find(marker) > 0
    ]
    if marker_positions:
        marker_pos = min(marker_positions)
        window_start = max(0, marker_pos - 1024)
        if window_start % 2:
            window_start += 1
        for invalid_pos in range(window_start, marker_pos, 2):
            if compact_hex[invalid_pos : invalid_pos + 2] == "fe":
                return compact_hex[: invalid_pos + 2]
        return compact_hex[:marker_pos]

    if len(compact_hex) < 4:
        return compact_hex
    try:
        metadata_len_bytes = int(compact_hex[-4:], 16)
    except ValueError:
        return compact_hex

    metadata_hex_len = metadata_len_bytes * 2
    metadata_start = len(compact_hex) - 4 - metadata_hex_len
    if metadata_len_bytes <= 0 or metadata_start < 0:
        return compact_hex
    try:
        first_metadata_byte = int(compact_hex[metadata_start : metadata_start + 2], 16)
    except ValueError:
        return compact_hex
    return compact_hex[:metadata_start] if 0xA0 <= first_metadata_byte <= 0xBF else compact_hex


def artifact_json_files(contract_dir: Path) -> List[Path]:
    if not contract_dir.exists() or not contract_dir.is_dir():
        return []
    files: List[Path] = []
    for path in sorted(contract_dir.rglob("*.json")):
        if path.name.endswith(".dbg.json"):
            continue
        if any(part in DEFAULT_SKIP_DIR_NAMES for part in path.parts):
            continue
        files.append(path)
    return files


def path_priority(path: Sequence[str], prefer_bytecode: str) -> int:
    joined = ".".join(path).lower()
    is_deployed = "deployedbytecode" in joined or "deployed_bytecode" in joined or "runtime" in joined
    is_creation = "bytecode" in joined and not is_deployed

    if prefer_bytecode == "deployed":
        if is_deployed:
            return 300
        if is_creation:
            return 200
    else:
        if is_creation:
            return 300
        if is_deployed:
            return 200
    return 100


def find_bytecode_in_artifact(data: Dict[str, Any], prefer_bytecode: str) -> Optional[Tuple[str, str, int]]:
    choices: List[Tuple[str, str, int]] = []
    for path in BYTECODE_PATHS:
        raw = bytecode_from_value(get_nested(data, path))
        compact = strip_hex_bytecode(raw)
        if compact:
            choices.append((raw, ".".join(path), path_priority(path, prefer_bytecode)))
    if not choices:
        return None
    return max(choices, key=lambda item: (item[2], len(strip_hex_bytecode(item[0]))))


def choose_artifact(contract_dir: Path, contract_file: str, prefer_bytecode: str) -> Optional[ArtifactChoice]:
    stem = Path(contract_file).stem.lower()
    choices: List[ArtifactChoice] = []
    for json_path in artifact_json_files(contract_dir):
        data = read_json(json_path)
        if not data:
            continue
        found = find_bytecode_in_artifact(data, prefer_bytecode)
        if not found:
            continue
        bytecode, key_path, priority = found
        path_stem = json_path.stem.lower()
        name_score = 50 if path_stem == stem else 20 if stem in path_stem or path_stem in stem else 0
        choices.append(ArtifactChoice(json_path, bytecode, key_path, priority + name_score))
    if not choices:
        return None
    return max(choices, key=lambda item: (item.priority, len(strip_hex_bytecode(item.bytecode))))


def disassemble_bytecode(
    value: Any,
    include_push_data: bool,
    keep_solc_metadata: bool,
) -> Tuple[str, List[str]]:
    compact = strip_hex_bytecode(value)
    if not compact:
        return "", ["empty bytecode"]
    if not keep_solc_metadata:
        compact = strip_solc_metadata(compact)

    byte_values = bytes.fromhex(compact)
    tokens: List[str] = []
    unknown: List[str] = []
    pc = 0

    while pc < len(byte_values):
        opcode_value = byte_values[pc]
        opcode = OPCODES.get(opcode_value)
        if opcode is None:
            opcode = f"UNKNOWN_0x{opcode_value:02x}"
            unknown.append(f"{opcode}@{pc}")
        tokens.append(opcode)
        pc += 1

        if 0x60 <= opcode_value <= 0x7F:
            push_size = opcode_value - 0x5F
            push_data = byte_values[pc : pc + push_size]
            if include_push_data:
                tokens.append(f"0x{push_data.hex()}")
            pc += push_size

    return " ".join(tokens), unknown


def artifact_dir_for_contract(artifacts_dir: Path, contract_file: str) -> Path:
    return artifacts_dir / contract_file


def process_rows(
    rows: List[Dict[str, str]],
    artifacts_dir: Path,
    file_column: str,
    opcode_column: str,
    prefer_bytecode: str,
    include_push_data: bool,
    keep_solc_metadata: bool,
) -> Tuple[List[Dict[str, Any]], List[str], List[str]]:
    output_rows: List[Dict[str, Any]] = []
    missing: List[str] = []
    unknown_reports: List[str] = []

    for row in rows:
        filename = str(row.get(file_column, "")).strip()
        new_row = dict(row)
        opcode = ""

        if not filename:
            missing.append("<empty file column>")
        else:
            contract_dir = artifact_dir_for_contract(artifacts_dir, filename)
            choice = choose_artifact(contract_dir, filename, prefer_bytecode)
            if choice is None:
                missing.append(f"{filename}: artifact JSON dengan bytecode tidak ditemukan di {contract_dir}")
            else:
                opcode, unknown = disassemble_bytecode(
                    choice.bytecode,
                    include_push_data=include_push_data,
                    keep_solc_metadata=keep_solc_metadata,
                )
                if unknown:
                    unknown_reports.append(
                        f"{filename}: {choice.path} ({choice.key_path}) -> {', '.join(unknown[:10])}"
                    )
                if not opcode:
                    missing.append(f"{filename}: bytecode kosong di {choice.path}")

        new_row[opcode_column] = opcode
        output_rows.append(new_row)

    return output_rows, missing, unknown_reports


def output_fieldnames(input_fields: Sequence[str], opcode_column: str) -> List[str]:
    fields = [field for field in input_fields if field != opcode_column]
    if "file" in fields:
        fields.insert(fields.index("file") + 1, opcode_column)
    else:
        fields.append(opcode_column)
    return fields


def report(title: str, items: Sequence[str], limit: int = 15) -> None:
    if not items:
        return
    print(f"{title}: {len(items)}")
    for item in items[:limit]:
        print(f"  - {item}")
    if len(items) > limit:
        print(f"  ... {len(items) - limit} lainnya")


def main() -> int:
    args = parse_args()

    train_split = resolve_path(args.train_split)
    test_split = resolve_path(args.test_split)
    artifacts_dir = resolve_path(args.artifacts_dir)
    output_train = resolve_path(args.output_train)
    output_test = resolve_path(args.output_test)

    try:
        train_rows, train_fields = read_csv(train_split)
        test_rows, test_fields = read_csv(test_split)
        if args.file_column not in train_fields or args.file_column not in test_fields:
            raise ValueError(f"Kolom file '{args.file_column}' wajib ada di train dan test CSV.")
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    train_output, train_missing, train_unknown = process_rows(
        rows=train_rows,
        artifacts_dir=artifacts_dir,
        file_column=args.file_column,
        opcode_column=args.opcode_column,
        prefer_bytecode=args.prefer_bytecode,
        include_push_data=args.include_push_data,
        keep_solc_metadata=args.keep_solc_metadata,
    )
    test_output, test_missing, test_unknown = process_rows(
        rows=test_rows,
        artifacts_dir=artifacts_dir,
        file_column=args.file_column,
        opcode_column=args.opcode_column,
        prefer_bytecode=args.prefer_bytecode,
        include_push_data=args.include_push_data,
        keep_solc_metadata=args.keep_solc_metadata,
    )

    train_fields_out = output_fieldnames(train_fields, args.opcode_column)
    test_fields_out = output_fieldnames(test_fields, args.opcode_column)
    write_csv(output_train, train_output, train_fields_out)
    write_csv(output_test, test_output, test_fields_out)

    print("Selesai membuat CSV split dengan kolom opcode.")
    print(f"Train rows : {len(train_output)} -> {output_train}")
    print(f"Test rows  : {len(test_output)} -> {output_test}")
    print(f"Artifacts  : {artifacts_dir}")
    print(f"Opcode col : {args.opcode_column}")
    print(f"Bytecode   : prefer {args.prefer_bytecode}")

    report("Train artifact/opcode kosong", train_missing)
    report("Test artifact/opcode kosong", test_missing)
    report("Train unknown opcode byte", train_unknown)
    report("Test unknown opcode byte", test_unknown)

    has_errors = bool(train_missing or test_missing or train_unknown or test_unknown)
    if args.strict and has_errors:
        print("ERROR: strict aktif dan masih ada masalah opcode.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
