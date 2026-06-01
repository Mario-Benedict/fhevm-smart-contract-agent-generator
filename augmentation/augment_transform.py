#!/usr/bin/env python3
"""
FHEVM Smart Contract Augmentation Pipeline
===========================================
Pipeline terpadu: augment -> compile -> augment -> compile (interleaved).

4 Tipe Augmentasi (tidak ada vulnerability injection, tidak ada LLM):
  1. rename      - Variable renaming
  2. expression  - Expression substitution
  3. fhe_swap    - FHE type swapping
  4. dead_code   - Dead code injection

Fitur utama:
  [1] BALANCED AUGMENTATION
      Distribusi kelas dibaca dari dataset/final_labels.jsonl (read-only).
      Kelas minoritas mendapat lebih banyak variant per kontrak.
      Semua kontrak diaugment setidaknya BASE_VARIANTS_MIN per transform.
      Label augmented MEWARISI flag vulnerability dari kontrak aslinya.

  [2] METADATA KOMPILASI
      Setiap kontrak yang berhasil compile disimpan metadatanya:
      bytecode, deployed bytecode, ABI, contract name, dsb.
      Folder: augmentation/metadata/<transform_type>/<contract>.json

  [3] SEMUA OUTPUT DI DALAM augmentation/
      dataset/final_labels.jsonl hanya DIBACA sebagai referensi, tidak diubah.

  [4] RESUMABLE
      Pipeline bisa dihentikan kapan saja dan dilanjutkan.
      Pair yang sudah dikerjakan dilewati.

Output:
  augmentation/contracts_output/<transform_type>/<name>__<transform>_<idx>.sol
  augmentation/metadata/<transform_type>/<name>__<transform>_<idx>.json
  augmentation/labels/augmented_labels.jsonl
  augmentation/progress/pipeline_progress.json
  augmentation/logs/pipeline.log
  augmentation/logs/failed_transforms.jsonl
"""

import os
import sys
import json
import math
import hashlib
import logging
from collections import Counter
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Tuple

# ── Path setup ────────────────────────────────────────────────────────────────
AUGMENTATION_DIR = Path(__file__).parent
sys.path.insert(0, str(AUGMENTATION_DIR))

if sys.platform == 'win32':
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

# ── Import transformers ───────────────────────────────────────────────────────
try:
    from src.ast_parser import ContractMetadata, parse_all_contracts
    from src.transformer_rename import apply_variable_renaming
    from src.transformer_expression import apply_expression_substitution
    from src.transformer_fhe_types import get_all_swap_variants
    from src.transformer_dead_code import apply_dead_code_injection
    from src.validator import validate_contract
except ImportError as e:
    print(f"[ERROR] Import gagal: {e}")
    print("  Pastikan menjalankan dari root project.")
    sys.exit(1)

# ── Output paths (semua di dalam augmentation/) ───────────────────────────────
CONTRACTS_INPUT  = AUGMENTATION_DIR / "contracts_input"
CONTRACTS_OUTPUT = AUGMENTATION_DIR / "contracts_output"
METADATA_DIR     = AUGMENTATION_DIR / "metadata"
LABELS_DIR       = AUGMENTATION_DIR / "labels"
PROGRESS_DIR     = AUGMENTATION_DIR / "progress"
LOGS_DIR         = AUGMENTATION_DIR / "logs"

LABELS_FILE   = LABELS_DIR / "augmented_labels.jsonl"
PROGRESS_FILE = PROGRESS_DIR / "pipeline_progress.json"
FAILURES_FILE = LOGS_DIR / "failed_transforms.jsonl"

# Referensi distribusi (READ-ONLY, tidak diubah) — absolut agar works dari cwd apapun
REFERENCE_LABELS_FILE = AUGMENTATION_DIR.parent / "dataset" / "final_labels.jsonl"


# ── Konfigurasi pipeline ──────────────────────────────────────────────────────
TRANSFORM_TYPES = ["rename", "expression", "fhe_swap", "dead_code"]

# Variant per transform per kontrak
BASE_VARIANTS_MIN  = 1   # minimum untuk SEMUA kontrak (termasuk kelas mayoritas)
VARIANTS_UPPER_CAP = 8   # maksimum agar tidak berlebihan

CONFIRM_EVERY = 10000      # konfirmasi user setiap N kontrak berhasil

# Strategi per tipe
RENAME_STRATEGIES = [0, 1, 2]
EXPR_STRATEGIES   = ["fhe", "combined", "plain"]
DEAD_CODE_STRATEGY_SETS = [
    ["comment"],
    ["comment", "unreachable_require"],
    ["comment", "dead_branch"],
]


# ═════════════════════════════════════════════════════════════════════════════
# Logging
# ═════════════════════════════════════════════════════════════════════════════

def setup_logging() -> logging.Logger:
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("aug_pipeline")
    logger.setLevel(logging.INFO)
    if logger.handlers:
        return logger
    fh = logging.FileHandler(LOGS_DIR / "pipeline.log", encoding="utf-8")
    fh.setLevel(logging.INFO)
    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)
    fmt = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s', datefmt='%H:%M:%S')
    fh.setFormatter(fmt)
    ch.setFormatter(fmt)
    logger.addHandler(fh)
    logger.addHandler(ch)
    return logger


# ═════════════════════════════════════════════════════════════════════════════
# Setup direktori
# ═════════════════════════════════════════════════════════════════════════════

def ensure_dirs():
    """Buat semua direktori output yang diperlukan."""
    for d in [CONTRACTS_OUTPUT, METADATA_DIR, LABELS_DIR, PROGRESS_DIR, LOGS_DIR]:
        d.mkdir(parents=True, exist_ok=True)
    for t in TRANSFORM_TYPES:
        (CONTRACTS_OUTPUT / t).mkdir(parents=True, exist_ok=True)
        (METADATA_DIR / t).mkdir(parents=True, exist_ok=True)


# ═════════════════════════════════════════════════════════════════════════════
# Distribusi kelas & augmentation plan
# ═════════════════════════════════════════════════════════════════════════════

def load_label_map() -> Dict[str, dict]:
    """
    Load label map dari dataset/final_labels.jsonl (read-only).
    Returns: {filename -> label_dict}
    """
    label_map = {}
    if not REFERENCE_LABELS_FILE.exists():
        return label_map
    with open(REFERENCE_LABELS_FILE, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    label = json.loads(line)
                    label_map[label['file']] = label
                except Exception:
                    pass
    return label_map


def get_category(label: dict) -> str:
    """Convert label dict ke category string untuk distribusi."""
    parts = []
    if label.get('acl_misconfig', 0):                    parts.append('acl')
    if label.get('arithmetic_overflow_underflow', 0):     parts.append('arith')
    if label.get('callback_replay', 0):                   parts.append('cb')
    return '+'.join(parts) if parts else 'safe'


def compute_augmentation_plan(
    contracts: List[ContractMetadata],
    label_map: Dict[str, dict],
) -> Tuple[Dict[str, int], Dict[str, int], Dict[str, str]]:
    """
    Hitung jumlah variant per transform per kontrak berdasarkan distribusi kelas.

    Logika balancing (post-augmentation parity):
    - Tentukan jumlah kontrak per kelas dari final_labels.jsonl
    - Hitung jumlah total sample setelah augmentasi untuk kelas MAYORITAS
      (yang mendapat BASE_VARIANTS_MIN):
        target = majority_count * (1 + num_transforms * BASE_VARIANTS_MIN)
    - Untuk tiap kelas minoritas, hitung berapa variant yang dibutuhkan agar
      total sample kelas itu >= target:
        total_after = current_count + len(class_contracts) * num_transforms * variants
        variants = ceil((target - current_count) / (len(class_contracts) * num_transforms))
    - Semua kontrak mendapat minimal BASE_VARIANTS_MIN
    - Cap di VARIANTS_UPPER_CAP
    - Kontrak yang tidak ada di label_map mendapat BASE_VARIANTS_MIN

    Returns:
        variant_counts: {filename -> variants_per_transform}
        distribution:   {category -> count}  (distribusi original)
        contract_cats:  {filename -> category}
    """
    # Kategorisasi tiap kontrak
    contract_cats: Dict[str, str] = {}
    for c in contracts:
        label = label_map.get(c.filename, {})
        contract_cats[c.filename] = get_category(label)

    # Distribusi kelas saat ini
    distribution: Dict[str, int] = dict(Counter(contract_cats.values()))

    if not distribution:
        return (
            {c.filename: BASE_VARIANTS_MIN for c in contracts},
            {},
            contract_cats,
        )

    # Kelompokkan contracts per kategori
    cats_to_contracts: Dict[str, List[ContractMetadata]] = {}
    for c in contracts:
        cat = contract_cats[c.filename]
        cats_to_contracts.setdefault(cat, []).append(c)

    # Target post-augmentation: mayoritas mendapat BASE_VARIANTS_MIN per transform
    # majority_after = majority_count + majority_count * num_transforms * BASE_VARIANTS_MIN
    #                = majority_count * (1 + num_transforms * BASE_VARIANTS_MIN)
    majority_count = max(distribution.values())
    target_after   = majority_count * (1 + len(TRANSFORM_TYPES) * BASE_VARIANTS_MIN)

    variant_counts: Dict[str, int] = {}

    for cat, cat_contracts in cats_to_contracts.items():
        current_count = distribution[cat]

        # Hitung berapa TOTAL sample baru yang dibutuhkan kelas ini untuk >= target_after
        # total_after = current_count + len(cat_contracts) * num_transforms * variants
        # => variants = ceil((target_after - current_count) / (len(cat_contracts) * num_transforms))
        needed_aug = max(0, target_after - current_count)

        if needed_aug == 0:
            # Sudah di atas atau sama dengan target (kelas mayoritas)
            variants = BASE_VARIANTS_MIN
        else:
            variants = math.ceil(needed_aug / (len(cat_contracts) * len(TRANSFORM_TYPES)))
            variants = max(variants, BASE_VARIANTS_MIN)
            variants = min(variants, VARIANTS_UPPER_CAP)

        for c in cat_contracts:
            variant_counts[c.filename] = variants

    # Fallback untuk kontrak yang tidak ada di label_map
    for c in contracts:
        if c.filename not in variant_counts:
            variant_counts[c.filename] = BASE_VARIANTS_MIN

    return variant_counts, distribution, contract_cats


# ═════════════════════════════════════════════════════════════════════════════
# Progress tracking
# ═════════════════════════════════════════════════════════════════════════════

def load_progress() -> dict:
    if PROGRESS_FILE.exists():
        with open(PROGRESS_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    return {
        'meta': {
            'created':       datetime.now().isoformat(),
            'last_updated':  datetime.now().isoformat(),
            'total_success': 0,
            'total_failed':  0,
            'total_skipped': 0,
        },
        'done':          {},   # "filename|transform|idx" -> status
        'next_label_id': 1,
    }


def save_progress(progress: dict):
    progress['meta']['last_updated'] = datetime.now().isoformat()
    PROGRESS_DIR.mkdir(parents=True, exist_ok=True)
    with open(PROGRESS_FILE, 'w', encoding='utf-8') as f:
        json.dump(progress, f, indent=2)


def _key(filename: str, transform_type: str, variant_idx: int) -> str:
    return f"{filename}|{transform_type}|{variant_idx}"


def is_done(progress: dict, filename: str, transform_type: str, variant_idx: int) -> bool:
    return _key(filename, transform_type, variant_idx) in progress['done']


def mark_done(progress: dict, filename: str, transform_type: str, variant_idx: int, status: str):
    progress['done'][_key(filename, transform_type, variant_idx)] = status


# ═════════════════════════════════════════════════════════════════════════════
# Augmentasi
# ═════════════════════════════════════════════════════════════════════════════

def _source_hash(source: str) -> str:
    return hashlib.md5(source.encode()).hexdigest()[:8]


def generate_variant(
    meta: ContractMetadata,
    transform_type: str,
    variant_idx: int,
    seen_hashes: set,
) -> Optional[str]:
    """
    Generate satu variant augmented dari kontrak.
    Return: augmented source, atau None jika tidak applicable / duplikat / error.
    """
    try:
        augmented: Optional[str] = None

        if transform_type == "rename":
            strategy = RENAME_STRATEGIES[variant_idx % len(RENAME_STRATEGIES)]
            seed = hash(meta.filename + f"rename_{variant_idx}") % (2 ** 31)
            augmented = apply_variable_renaming(meta, strategy=strategy, seed=seed)

        elif transform_type == "expression":
            strategy = EXPR_STRATEGIES[variant_idx % len(EXPR_STRATEGIES)]
            seed = hash(meta.filename + f"expr_{variant_idx}") % (2 ** 31)
            augmented = apply_expression_substitution(
                meta,
                strategy=strategy,
                seed=seed,
                max_substitutions=3 + variant_idx,
            )

        elif transform_type == "fhe_swap":
            if not getattr(meta, 'fhe_types_used', None):
                return None
            swap_variants = get_all_swap_variants(meta)
            if not swap_variants or variant_idx >= len(swap_variants):
                return None
            
            # Handle different return formats from get_all_swap_variants
            variant = swap_variants[variant_idx]
            if isinstance(variant, (tuple, list)) and len(variant) >= 3:
                augmented = variant[2]  # 3rd element is the transformed source
            elif isinstance(variant, str):
                augmented = variant  # Direct string source
            else:
                return None
            
            if not augmented:
                return None

        elif transform_type == "dead_code":
            strategies = DEAD_CODE_STRATEGY_SETS[variant_idx % len(DEAD_CODE_STRATEGY_SETS)]
            seed = hash(meta.filename + f"dead_{variant_idx}") % (2 ** 31)
            augmented = apply_dead_code_injection(
                meta,
                n_injections=2,
                strategies=strategies,
                seed=seed,
            )

        if augmented is None:
            return None

        h = _source_hash(augmented)
        if h in seen_hashes or augmented == meta.raw_source:
            return None
        seen_hashes.add(h)

        return augmented

    except Exception:
        return None


# ═════════════════════════════════════════════════════════════════════════════
# Output: simpan kontrak, label, metadata
# ═════════════════════════════════════════════════════════════════════════════

def save_contract(
    source: str,
    orig_filename: str,
    transform_type: str,
    variant_idx: int,
) -> str:
    """Simpan augmented contract. Return: aug_filename."""
    base = orig_filename.replace(".sol", "")
    aug_filename = f"{base}__{transform_type}_{variant_idx:04d}.sol"
    output_path = CONTRACTS_OUTPUT / transform_type / aug_filename
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(source)
    return aug_filename


def append_label(
    filename: str,
    label_id: int,
    original_label: dict,
):
    """
    Append label entry ke augmented_labels.jsonl.
    Format identik dengan dataset/final_labels.jsonl.
    Label MEWARISI flag vulnerability dari kontrak aslinya
    (transformasi tidak menambah atau menghapus vulnerability).
    """
    label = {
        "id":                            f"{label_id:05d}",
        "file":                          filename,
        "acl_misconfig":                 original_label.get("acl_misconfig", 0),
        "arithmetic_overflow_underflow": original_label.get("arithmetic_overflow_underflow", 0),
        "callback_replay":               original_label.get("callback_replay", 0),
    }
    with open(LABELS_FILE, 'a', encoding='utf-8') as f:
        f.write(json.dumps(label) + '\n')


def save_metadata(
    aug_filename: str,
    orig_filename: str,
    transform_type: str,
    variant_idx: int,
    label_id: int,
    source: str,
    validation_result,
    original_label: dict,
):
    """
    Simpan metadata kompilasi ke metadata/<transform_type>/<aug_filename>.json.
    Berisi: bytecode, deployed_bytecode, ABI, contract name, info sumber, dsb.
    """
    metadata = {
        "file":            aug_filename,
        "original_file":   orig_filename,
        "transform_type":  transform_type,
        "variant_idx":     variant_idx,
        "label_id":        label_id,
        "timestamp":       datetime.now().isoformat(),
        # Source info
        "source_lines":    len(source.splitlines()),
        "source_size_bytes": len(source.encode('utf-8')),
        # Label info (inherited dari original)
        "label": {
            "acl_misconfig":                 original_label.get("acl_misconfig", 0),
            "arithmetic_overflow_underflow": original_label.get("arithmetic_overflow_underflow", 0),
            "callback_replay":               original_label.get("callback_replay", 0),
        },
        # Compilation artifacts
        "contract_name":     validation_result.contract_name,
        "abi":               validation_result.abi,
        "bytecode":          validation_result.bytecode,
        "deployed_bytecode": validation_result.deployed_bytecode,
    }

    meta_path = METADATA_DIR / transform_type / aug_filename.replace('.sol', '.json')
    with open(meta_path, 'w', encoding='utf-8') as f:
        json.dump(metadata, f, indent=2, ensure_ascii=False)


# ═════════════════════════════════════════════════════════════════════════════
# Failure logging
# ═════════════════════════════════════════════════════════════════════════════

def log_failure(orig_filename: str, transform_type: str, variant_idx: int, error: str):
    entry = {
        "file":      orig_filename,
        "transform": transform_type,
        "variant":   variant_idx,
        "error":     error[:300],
        "timestamp": datetime.now().isoformat(),
    }
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    with open(FAILURES_FILE, 'a', encoding='utf-8') as f:
        f.write(json.dumps(entry) + '\n')


# ═════════════════════════════════════════════════════════════════════════════
# Status display
# ═════════════════════════════════════════════════════════════════════════════

def print_status(progress: dict, distribution: dict = None, variant_plan: dict = None):
    meta    = progress['meta']
    success = meta['total_success']
    failed  = meta['total_failed']
    skipped = meta['total_skipped']
    total   = success + failed + skipped
    pct     = (success / total * 100) if total > 0 else 0.0

    print(f"\n{'=' * 60}")
    print("  AUGMENTATION PIPELINE STATUS")
    print(f"{'=' * 60}")
    print(f"  Berhasil  :  {success:7,d}")
    print(f"  Gagal     :  {failed:7,d}")
    print(f"  Skipped   :  {skipped:7,d}")
    print(f"  Total     :  {total:7,d}  ({pct:.1f}% berhasil)")
    print(f"  Next ID   :  {progress['next_label_id']}")
    print(f"  Updated   :  {meta['last_updated']}")

    if LABELS_FILE.exists():
        try:
            with open(LABELS_FILE, 'r', encoding='utf-8') as f:
                lcount = sum(1 for _ in f)
            print(f"  Labels    :  {lcount:,d} entries")
        except Exception:
            pass

    if distribution:
        print(f"\n  DISTRIBUSI KELAS ORIGINAL (dari {REFERENCE_LABELS_FILE.name}):")
        max_c = max(distribution.values()) if distribution else 1
        for cat, count in sorted(distribution.items(), key=lambda x: -x[1]):
            bar  = '█' * int(count * 30 / max_c)
            pct2 = count / sum(distribution.values()) * 100 if distribution else 0
            print(f"    {cat:35s}: {count:5d} ({pct2:4.1f}%)  {bar}")

    if variant_plan:
        counts = Counter(variant_plan.values())
        print(f"\n  VARIANT PER TRANSFORM (plan):")
        for v, n in sorted(counts.items()):
            print(f"    {v} variant/transform  -> {n:5d} kontrak")

    print(f"{'=' * 60}\n")


# ═════════════════════════════════════════════════════════════════════════════
# Pipeline utama
# ═════════════════════════════════════════════════════════════════════════════

def run_pipeline(logger: logging.Logger):
    """Jalankan pipeline augmentasi interleaved (augment -> compile per item)."""
    ensure_dirs()

    logger.info("=" * 60)
    logger.info("FHEVM Smart Contract Augmentation Pipeline")
    logger.info(f"  Input    : {CONTRACTS_INPUT}")
    logger.info(f"  Output   : {CONTRACTS_OUTPUT}")
    logger.info(f"  Metadata : {METADATA_DIR}")
    logger.info(f"  Labels   : {LABELS_FILE}")
    logger.info(f"  Confirm  : setiap {CONFIRM_EVERY} berhasil")
    logger.info("=" * 60)

    # ── [1] Load kontrak ──────────────────────────────────────────────────────
    logger.info("\n[1/3] Loading contracts dari contracts_input/...")
    contracts: List[ContractMetadata] = parse_all_contracts(str(CONTRACTS_INPUT))
    if not contracts:
        logger.error("Tidak ada kontrak ditemukan di contracts_input/!")
        return
    logger.info(f"  Loaded: {len(contracts):,d} contracts")

    # ── [2] Hitung augmentation plan (balanced) ───────────────────────────────
    logger.info("\n[2/3] Menghitung augmentation plan (balanced)...")
    label_map = load_label_map()
    if not label_map:
        logger.warning(f"  Tidak ditemukan label di {REFERENCE_LABELS_FILE}. "
                       f"Semua kontrak dianggap 'safe' dengan {BASE_VARIANTS_MIN} variant.")

    variant_plan, distribution, contract_cats = compute_augmentation_plan(contracts, label_map)

    # Log distribusi
    if distribution:
        max_c = max(distribution.values())
        logger.info(f"  Distribusi kelas ({len(distribution)} kategori):")
        for cat, count in sorted(distribution.items(), key=lambda x: -x[1]):
            logger.info(f"    {cat:35s}: {count:5d}")
        logger.info(f"  Target balancing: semua kelas menuju {max_c}")

    # Log plan summary
    plan_counts = Counter(variant_plan.values())
    logger.info(f"  Augmentation plan:")
    for v, n in sorted(plan_counts.items()):
        logger.info(f"    {v} variant/transform -> {n:5d} kontrak "
                    f"(= {n * len(TRANSFORM_TYPES) * v:,d} total items)")

    total_planned = sum(
        variant_plan.get(c.filename, BASE_VARIANTS_MIN) * len(TRANSFORM_TYPES)
        for c in contracts
    )
    logger.info(f"  Total work items: {total_planned:,d}")

    # ── [3] Pipeline loop ─────────────────────────────────────────────────────
    progress = load_progress()
    seen_hashes: set = set()
    success_batch_ctr = 0

    already_done = len(progress['done'])
    logger.info(f"\n[3/3] Pipeline dimulai (already done: {already_done:,d})")
    logger.info("")

    for meta in contracts:
        n_variants = variant_plan.get(meta.filename, BASE_VARIANTS_MIN)
        original_label = label_map.get(meta.filename, {})

        for transform_type in TRANSFORM_TYPES:
            for variant_idx in range(n_variants):

                # Skip jika sudah dikerjakan
                if is_done(progress, meta.filename, transform_type, variant_idx):
                    continue

                # ── Augment ──────────────────────────────────────────────────
                augmented = generate_variant(meta, transform_type, variant_idx, seen_hashes)

                if augmented is None:
                    mark_done(progress, meta.filename, transform_type, variant_idx, "skipped")
                    progress['meta']['total_skipped'] += 1
                    save_progress(progress)
                    continue

                # ── Compile / Validate ────────────────────────────────────────
                result = validate_contract(augmented, meta.filename)

                if result.is_valid:
                    # ── Berhasil: simpan kontrak + metadata + label ────────────
                    label_id     = progress['next_label_id']
                    aug_filename = save_contract(augmented, meta.filename, transform_type, variant_idx)

                    # Metadata (bytecode, ABI, dll)
                    save_metadata(
                        aug_filename   = aug_filename,
                        orig_filename  = meta.filename,
                        transform_type = transform_type,
                        variant_idx    = variant_idx,
                        label_id       = label_id,
                        source         = augmented,
                        validation_result = result,
                        original_label = original_label,
                    )

                    # Label (mewarisi label asli)
                    append_label(aug_filename, label_id, original_label)

                    progress['next_label_id']        += 1
                    progress['meta']['total_success'] += 1
                    success_batch_ctr                 += 1
                    mark_done(progress, meta.filename, transform_type, variant_idx, "success")
                    save_progress(progress)

                    logger.info(
                        f"  OK  [{transform_type:10s}] {meta.filename} v{variant_idx}"
                        f"  ->  {aug_filename}"
                    )

                    # ── Konfirmasi setiap CONFIRM_EVERY ───────────────────────
                    if success_batch_ctr >= CONFIRM_EVERY:
                        print_status(progress, distribution, variant_plan)
                        try:
                            resp = input(
                                f"  [{progress['meta']['total_success']:,d} berhasil]"
                                f"  Lanjut? (y/n): "
                            ).strip().lower()
                        except (EOFError, KeyboardInterrupt):
                            resp = 'n'
                        if resp != 'y':
                            logger.info("Pipeline dijeda oleh user.")
                            print("Pipeline dijeda. Jalankan lagi untuk melanjutkan.")
                            return
                        success_batch_ctr = 0

                else:
                    # ── Gagal compile: log dan skip ───────────────────────────
                    log_failure(meta.filename, transform_type, variant_idx, result.error_message)
                    mark_done(progress, meta.filename, transform_type, variant_idx, "failed")
                    progress['meta']['total_failed'] += 1
                    save_progress(progress)
                    logger.warning(
                        f"  FAIL [{transform_type:10s}] {meta.filename} v{variant_idx}"
                        f"  : {result.error_message[:250]}"
                    )

    logger.info("\nPipeline selesai!")
    print_status(progress, distribution, variant_plan)


# ═════════════════════════════════════════════════════════════════════════════
# CLI Commands
# ═════════════════════════════════════════════════════════════════════════════

def cmd_run():
    logger = setup_logging()
    run_pipeline(logger)


def cmd_status():
    """Tampilkan status pipeline saat ini + distribusi kelas."""
    label_map = load_label_map()

    contracts = parse_all_contracts(str(CONTRACTS_INPUT))
    if contracts:
        _, distribution, _ = compute_augmentation_plan(contracts, label_map)
    else:
        distribution = {}

    variant_plan = None
    if contracts and distribution:
        vp, _, _ = compute_augmentation_plan(contracts, label_map)
        variant_plan = vp

    if not PROGRESS_FILE.exists():
        print("Tidak ada progress file. Jalankan 'run' terlebih dahulu.")
        if distribution:
            print_status({'meta': {'total_success':0,'total_failed':0,'total_skipped':0,'last_updated':'-'}, 'next_label_id':1}, distribution, variant_plan)
        return

    with open(PROGRESS_FILE, 'r', encoding='utf-8') as f:
        progress = json.load(f)

    print_status(progress, distribution, variant_plan)

    # Breakdown per transform type
    status_by_type: Dict[str, Counter] = {t: Counter() for t in TRANSFORM_TYPES}
    for key, status in progress['done'].items():
        parts = key.split('|')
        if len(parts) >= 2 and parts[1] in status_by_type:
            status_by_type[parts[1]][status] += 1

    print("  BREAKDOWN PER TRANSFORM TYPE:")
    print(f"  {'Type':<12} {'Success':>8} {'Failed':>8} {'Skipped':>8}")
    print(f"  {'-'*42}")
    for t in TRANSFORM_TYPES:
        c = status_by_type[t]
        print(f"  {t:<12} {c.get('success',0):>8,d} {c.get('failed',0):>8,d} {c.get('skipped',0):>8,d}")
    print()


def cmd_reset():
    """Reset semua progress (konfirmasi diperlukan)."""
    print("PERINGATAN: Ini akan menghapus progress, labels, metadata, dan log augmentasi.")
    try:
        resp = input("Reset semua progress? (y/n): ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        resp = 'n'
    if resp != 'y':
        print("Dibatalkan.")
        return

    import shutil
    removed = []
    for f in [PROGRESS_FILE, FAILURES_FILE, LABELS_FILE]:
        if f.exists():
            f.unlink()
            removed.append(f.name)
    # Hapus contracts_output & metadata isinya (bukan folder-nya)
    for base_dir in [CONTRACTS_OUTPUT, METADATA_DIR]:
        for sub in TRANSFORM_TYPES:
            sub_dir = base_dir / sub
            if sub_dir.exists():
                for item in sub_dir.iterdir():
                    if item.is_file():
                        item.unlink()
                removed.append(f"{base_dir.name}/{sub}/*")

    print(f"Dihapus: {', '.join(removed) if removed else '(tidak ada)'}")
    print("Progress direset. Jalankan 'run' untuk memulai dari awal.")


# ═════════════════════════════════════════════════════════════════════════════
# Entry point
# ═════════════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 2:
        print("""
FHEVM Smart Contract Augmentation Pipeline

4 tipe transformasi (tanpa LLM, tanpa vulnerability injection):
  rename     - Variable renaming
  expression - Expression substitution
  fhe_swap   - FHE type swapping (euint32 <-> euint64, dll)
  dead_code  - Dead code injection

Fitur:
  - Balanced: kelas minoritas mendapat lebih banyak augmentasi
  - Label diwarisi dari kontrak asli (bukan default safe)
  - Metadata kompilasi (bytecode, ABI) disimpan per kontrak
  - Resumable: bisa dihentikan dan dilanjutkan

Usage:
  python augmentation/augment_transform.py <command>

Commands:
  run      Jalankan / lanjutkan augmentation pipeline
  status   Tampilkan progress + distribusi kelas
  reset    Reset semua progress (konfirmasi diperlukan)
""")
        return

    cmd = sys.argv[1].lower()
    if cmd == 'run':
        cmd_run()
    elif cmd == 'status':
        cmd_status()
    elif cmd == 'reset':
        cmd_reset()
    else:
        print(f"Perintah tidak dikenal: '{cmd}'")
        print("Gunakan: run | status | reset")


if __name__ == '__main__':
    main()
