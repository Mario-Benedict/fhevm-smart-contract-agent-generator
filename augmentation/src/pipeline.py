"""
pipeline.py
Main orchestrator untuk augmentasi pipeline FHEVM smart contracts.

Pipeline:
1. Parse semua kontrak input
2. Analisis distribusi kelas (skewness)
3. Apply transformasi bertahap:
   - Variable renaming    → target 1000 kontrak baru
   - Expression subst.    → target 500 kontrak baru
   - FHE type swapping    → target 300 kontrak baru
   - Dead code injection  → target 200 kontrak baru
4. Validasi semua hasil
5. Filter yang gagal compile
6. Output ke direktori hasil
"""

import os
import sys
import json
import math
import random
import hashlib
import logging
from collections import Counter
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Tuple

# Add src to path
sys.path.insert(0, os.path.dirname(__file__))

from src.ast_parser import (
    ContractMetadata, parse_all_contracts, get_class_distribution,
)
from src.transformer_rename import apply_variable_renaming
from src.transformer_expression import apply_expression_substitution, get_substitution_variants
from src.transformer_fhe_types import apply_fhe_type_swap, get_all_swap_variants
from src.transformer_dead_code import apply_dead_code_injection, get_dead_code_variants
from src.validator import validate_contract, ValidationResult


# ─── Setup logging ───────────────────────────────────────────────────────────

def setup_logging(log_dir: str) -> logging.Logger:
    os.makedirs(log_dir, exist_ok=True)
    
    logger = logging.getLogger("fhevm_augmentation")
    logger.setLevel(logging.INFO)
    
    # File handler
    fh = logging.FileHandler(os.path.join(log_dir, "pipeline.log"))
    fh.setLevel(logging.INFO)
    
    # Console handler
    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)
    
    formatter = logging.Formatter(
        '%(asctime)s [%(levelname)s] %(message)s',
        datefmt='%H:%M:%S'
    )
    fh.setFormatter(formatter)
    ch.setFormatter(formatter)
    
    logger.addHandler(fh)
    logger.addHandler(ch)
    
    return logger


# ─── Pipeline config ─────────────────────────────────────────────────────────

@dataclass
class PipelineConfig:
    input_dir: str
    output_dir: str
    log_dir: str
    
    # Target jumlah augmentasi per teknik
    target_rename: int = 1000
    target_expression: int = 500
    target_fhe_swap: int = 300
    target_dead_code: int = 200
    
    # Strategy settings
    rename_strategy: int = 0          # 0=prefix, 1=preserve_prefix, 2=readable
    expression_strategy: str = "combined"
    fhe_swap_strategy: str = "upcast_only"
    dead_code_injections: int = 2
    
    # Oversampling untuk kelas minoritas
    minority_oversample_factor: float = 2.0
    
    # Validasi
    run_validation: bool = True
    skip_validation_on_error: bool = True


# ─── Augmentation stats ───────────────────────────────────────────────────────

@dataclass
class AugmentationStats:
    total_input: int = 0
    total_generated: int = 0
    total_valid: int = 0
    total_invalid: int = 0
    
    rename_generated: int = 0
    rename_valid: int = 0
    
    expression_generated: int = 0
    expression_valid: int = 0
    
    fhe_swap_generated: int = 0
    fhe_swap_valid: int = 0
    
    dead_code_generated: int = 0
    dead_code_valid: int = 0
    
    class_distribution_before: Dict[str, int] = None
    class_distribution_after: Dict[str, int] = None
    
    def __post_init__(self):
        if self.class_distribution_before is None:
            self.class_distribution_before = {}
        if self.class_distribution_after is None:
            self.class_distribution_after = {}


# ─── Helper functions ─────────────────────────────────────────────────────────

def _save_augmented_contract(
    source: str,
    original_meta: ContractMetadata,
    output_dir: str,
    augmentation_type: str,
    variant_idx: int,
) -> str:
    """Simpan kontrak yang sudah di-augment ke output directory."""
    os.makedirs(output_dir, exist_ok=True)
    
    base_name = original_meta.filename.replace(".sol", "")
    new_filename = f"{base_name}__{augmentation_type}_{variant_idx:04d}.sol"
    output_path = os.path.join(output_dir, new_filename)
    
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(source)
    
    return output_path


def _compute_source_hash(source: str) -> str:
    return hashlib.md5(source.encode()).hexdigest()[:8]


def _get_minority_classes(
    distribution: Dict[str, int],
    threshold_percentile: float = 0.3,
) -> List[str]:
    """
    Identify kelas yang underrepresented.
    Kelas dengan jumlah < threshold * max_count dianggap minority.
    """
    if not distribution:
        return []
    
    max_count = max(distribution.values())
    threshold = max_count * threshold_percentile
    
    return [cls for cls, count in distribution.items() if count < threshold]


def _calculate_oversample_weights(
    contracts: List[ContractMetadata],
    minority_classes: List[str],
    oversample_factor: float,
) -> Dict[str, float]:
    """
    Hitung weight per kontrak untuk oversampling.
    Kontrak dari kelas minoritas dapat weight lebih tinggi.
    """
    weights = {}
    for meta in contracts:
        if meta.contract_class in minority_classes:
            weights[meta.filename] = oversample_factor
        else:
            weights[meta.filename] = 1.0
    return weights


# ─── Stage 1: Variable Renaming ──────────────────────────────────────────────

def stage_rename(
    contracts: List[ContractMetadata],
    config: PipelineConfig,
    stats: AugmentationStats,
    logger: logging.Logger,
) -> List[Tuple[str, str, str]]:
    """
    Variable renaming stage.
    Return: list of (source, original_filename, augtype)
    """
    logger.info("=" * 60)
    logger.info("STAGE 1: Variable Renaming")
    logger.info(f"Target: {config.target_rename} kontrak")
    
    results = []
    seen_hashes = set()
    
    # Hitung berapa variant per kontrak yang dibutuhkan
    n_per_contract = math.ceil(config.target_rename / len(contracts))
    n_per_contract = min(n_per_contract, 4)  # max 4 variant rename per kontrak
    
    for i, meta in enumerate(contracts):
        if len(results) >= config.target_rename:
            break
        
        for variant_idx in range(n_per_contract):
            if len(results) >= config.target_rename:
                break
            
            seed = hash(meta.filename + f"rename_{variant_idx}") % (2**31)
            strategy = variant_idx % 3  # rotate strategies
            
            try:
                augmented = apply_variable_renaming(meta, strategy=strategy, seed=seed)
                
                # Cek duplikat
                h = _compute_source_hash(augmented)
                if h in seen_hashes or augmented == meta.raw_source:
                    continue
                seen_hashes.add(h)
                
                results.append((augmented, meta.filename, f"rename_s{strategy}"))
                stats.rename_generated += 1
                
            except Exception as e:
                logger.warning(f"Rename gagal untuk {meta.filename}: {e}")
                continue
        
        if (i + 1) % 100 == 0:
            logger.info(f"  Processed {i+1}/{len(contracts)}, generated {len(results)}")
    
    logger.info(f"  Total rename variants: {len(results)}")
    return results


# ─── Stage 2: Expression Substitution ────────────────────────────────────────

def stage_expression(
    contracts: List[ContractMetadata],
    config: PipelineConfig,
    stats: AugmentationStats,
    logger: logging.Logger,
) -> List[Tuple[str, str, str]]:
    """
    Expression substitution stage.
    """
    logger.info("=" * 60)
    logger.info("STAGE 2: Expression Substitution")
    logger.info(f"Target: {config.target_expression} kontrak")
    
    results = []
    seen_hashes = set()
    
    strategies = ["fhe", "combined", "plain"]
    n_per_contract = math.ceil(config.target_expression / len(contracts))
    n_per_contract = min(n_per_contract, 3)
    
    for i, meta in enumerate(contracts):
        if len(results) >= config.target_expression:
            break
        
        for variant_idx in range(n_per_contract):
            if len(results) >= config.target_expression:
                break
            
            strategy = strategies[variant_idx % len(strategies)]
            seed = hash(meta.filename + f"expr_{variant_idx}") % (2**31)
            
            try:
                augmented = apply_expression_substitution(
                    meta,
                    strategy=strategy,
                    seed=seed,
                    max_substitutions=3 + variant_idx,
                )
                
                h = _compute_source_hash(augmented)
                if h in seen_hashes or augmented == meta.raw_source:
                    continue
                seen_hashes.add(h)
                
                results.append((augmented, meta.filename, f"expr_{strategy}"))
                stats.expression_generated += 1
                
            except Exception as e:
                logger.warning(f"Expression subst gagal untuk {meta.filename}: {e}")
                continue
    
    logger.info(f"  Total expression variants: {len(results)}")
    return results


# ─── Stage 3: FHE Type Swapping ──────────────────────────────────────────────

def stage_fhe_swap(
    contracts: List[ContractMetadata],
    config: PipelineConfig,
    stats: AugmentationStats,
    logger: logging.Logger,
) -> List[Tuple[str, str, str]]:
    """
    FHE type swapping stage.
    """
    logger.info("=" * 60)
    logger.info("STAGE 3: FHE Type Swapping")
    logger.info(f"Target: {config.target_fhe_swap} kontrak")
    
    results = []
    seen_hashes = set()
    
    # Filter hanya kontrak yang punya FHE types
    fhe_contracts = [m for m in contracts if m.fhe_types_used]
    logger.info(f"  Kontrak dengan FHE types: {len(fhe_contracts)}/{len(contracts)}")
    
    if not fhe_contracts:
        logger.warning("  Tidak ada kontrak FHE ditemukan!")
        return results
    
    for i, meta in enumerate(fhe_contracts):
        if len(results) >= config.target_fhe_swap:
            break
        
        try:
            # Get semua swap variants yang valid
            swap_variants = get_all_swap_variants(meta)
            
            for old_type, new_type, augmented in swap_variants:
                if len(results) >= config.target_fhe_swap:
                    break
                
                h = _compute_source_hash(augmented)
                if h in seen_hashes or augmented == meta.raw_source:
                    continue
                seen_hashes.add(h)
                
                results.append((
                    augmented,
                    meta.filename,
                    f"fheswap_{old_type}_to_{new_type}"
                ))
                stats.fhe_swap_generated += 1
                
        except Exception as e:
            logger.warning(f"FHE swap gagal untuk {meta.filename}: {e}")
            continue
    
    logger.info(f"  Total FHE swap variants: {len(results)}")
    return results


# ─── Stage 4: Dead Code Injection ────────────────────────────────────────────

def stage_dead_code(
    contracts: List[ContractMetadata],
    config: PipelineConfig,
    stats: AugmentationStats,
    logger: logging.Logger,
) -> List[Tuple[str, str, str]]:
    """
    Dead code injection stage.
    """
    logger.info("=" * 60)
    logger.info("STAGE 4: Dead Code Injection")
    logger.info(f"Target: {config.target_dead_code} kontrak")
    
    results = []
    seen_hashes = set()
    
    strategy_sets = [
        ["comment"],
        ["comment", "unreachable_require"],
        ["comment", "dead_branch"],
    ]
    
    n_per_contract = math.ceil(config.target_dead_code / len(contracts))
    n_per_contract = min(n_per_contract, 3)
    
    for i, meta in enumerate(contracts):
        if len(results) >= config.target_dead_code:
            break
        
        for variant_idx in range(n_per_contract):
            if len(results) >= config.target_dead_code:
                break
            
            strategies = strategy_sets[variant_idx % len(strategy_sets)]
            seed = hash(meta.filename + f"dead_{variant_idx}") % (2**31)
            
            try:
                augmented = apply_dead_code_injection(
                    meta,
                    n_injections=config.dead_code_injections,
                    strategies=strategies,
                    seed=seed,
                )
                
                h = _compute_source_hash(augmented)
                if h in seen_hashes or augmented == meta.raw_source:
                    continue
                seen_hashes.add(h)
                
                strategy_label = "+".join(strategies)
                results.append((augmented, meta.filename, f"dead_{strategy_label}"))
                stats.dead_code_generated += 1
                
            except Exception as e:
                logger.warning(f"Dead code gagal untuk {meta.filename}: {e}")
                continue
    
    logger.info(f"  Total dead code variants: {len(results)}")
    return results


# ─── Stage 5a: Create human-readable error report ─────────────────────────

def _save_error_report(
    invalid_details: List[dict],
    config: PipelineConfig,
    logger: logging.Logger,
):
    """
    Create human-readable error report dengan statistik breakdown.
    """
    report_path = os.path.join(config.log_dir, "validation_errors_report.txt")
    
    # Group errors by type
    errors_by_type = {}
    errors_by_file = {}
    
    for detail in invalid_details:
        error_msg = detail["error_message"]
        orig_file = detail["original_file"]
        aug_type = detail["augmentation_type"]
        
        # Categorize
        if "brace" in error_msg.lower():
            error_type = "Brace Mismatch"
        elif "paren" in error_msg.lower():
            error_type = "Parenthesis Mismatch"
        elif "type" in error_msg.lower():
            error_type = "Type Error"
        elif "pragma" in error_msg.lower():
            error_type = "Missing Pragma"
        elif "contract" in error_msg.lower():
            error_type = "Contract Declaration"
        else:
            error_type = "Other Error"
        
        if error_type not in errors_by_type:
            errors_by_type[error_type] = []
        errors_by_type[error_type].append(detail)
        
        if orig_file not in errors_by_file:
            errors_by_file[orig_file] = []
        errors_by_file[orig_file].append(detail)
    
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("=" * 70 + "\n")
        f.write("VALIDATION ERROR REPORT\n")
        f.write("=" * 70 + "\n\n")
        
        f.write(f"Total Errors: {len(invalid_details)}\n\n")
        
        # Error breakdown by type
        f.write("BREAKDOWN BY ERROR TYPE:\n")
        f.write("-" * 70 + "\n")
        for error_type in sorted(errors_by_type.keys()):
            count = len(errors_by_type[error_type])
            pct = (count * 100) // len(invalid_details) if invalid_details else 0
            f.write(f"{error_type:30s}: {count:4d} ({pct:3d}%)\n")
        f.write("\n")
        
        # Detailed errors by type
        f.write("\nDETAILED ERRORS BY TYPE:\n")
        f.write("=" * 70 + "\n")
        for error_type in sorted(errors_by_type.keys()):
            f.write(f"\n{error_type}:\n")
            f.write("-" * 70 + "\n")
            for i, detail in enumerate(errors_by_type[error_type][:5], 1):
                f.write(f"  {i}. {detail['original_file']}\n")
                f.write(f"     Type: {detail['augmentation_type']}\n")
                f.write(f"     Error: {detail['error_message'][:100]}\n")
            
            if len(errors_by_type[error_type]) > 5:
                f.write(f"  ... and {len(errors_by_type[error_type]) - 5} more\n")
        
        # Files dengan error terbanyak
        f.write("\n\n" + "=" * 70 + "\n")
        f.write("TOP FILES WITH MOST ERRORS:\n")
        f.write("=" * 70 + "\n")
        sorted_files = sorted(errors_by_file.items(), key=lambda x: len(x[1]), reverse=True)
        for i, (filename, errors) in enumerate(sorted_files[:10], 1):
            f.write(f"{i:2d}. {filename:40s}: {len(errors):3d} errors\n")
            for error in errors[:2]:
                f.write(f"    - {error['augmentation_type']}: {error['error_message'][:60]}\n")
    
    logger.info(f"  Error report saved to: {report_path}")


# ─── Stage 5b: Log invalid contracts for debugging ──────────────────────────

def _save_invalid_contracts(
    augmented_contracts: List[Tuple[str, str, str]],
    invalid_details: List[dict],
    config: PipelineConfig,
    logger: logging.Logger,
):
    """
    Simpan kontrak yang gagal validasi ke directory terpisah untuk debugging.
    Setiap file invalid disimpan dengan error message di comment.
    """
    if not invalid_details:
        return
    
    invalid_contracts_dir = os.path.join(config.log_dir, "invalid_contracts")
    os.makedirs(invalid_contracts_dir, exist_ok=True)
    
    # Build mapping original_file + aug_type -> error
    error_map = {}
    for detail in invalid_details:
        key = (detail["original_file"], detail["augmentation_type"])
        error_map[key] = detail["error_message"]
    
    saved_count = 0
    for source, orig_filename, aug_type in augmented_contracts:
        key = (orig_filename, aug_type)
        if key in error_map:
            # Add error message as comment at top
            error_comment = f"""// VALIDATION ERROR:
// {error_map[key]}
// Original file: {orig_filename}
// Augmentation type: {aug_type}
//
"""
            annotated_source = error_comment + source
            
            base_name = orig_filename.replace(".sol", "")
            filename = f"{base_name}__{aug_type}_INVALID.sol"
            filepath = os.path.join(invalid_contracts_dir, filename)
            
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(annotated_source)
            
            saved_count += 1
    
    if saved_count > 0:
        logger.info(f"  Saved {saved_count} invalid contracts to: {invalid_contracts_dir}")


# ─── Stage 5: Validation ─────────────────────────────────────────────────────

def stage_validate(
    augmented_contracts: List[Tuple[str, str, str]],
    config: PipelineConfig,
    stats: AugmentationStats,
    logger: logging.Logger,
) -> List[Tuple[str, str, str]]:
    """
    Validate semua augmented contracts.
    Return hanya yang valid.
    Simpan error details ke file untuk debugging.
    """
    logger.info("=" * 60)
    logger.info("STAGE 5: Validation")
    logger.info(f"  Validating {len(augmented_contracts)} contracts...")
    
    if not config.run_validation:
        logger.info("  Validation diskip (run_validation=False)")
        return augmented_contracts
    
    valid = []
    invalid_count = 0
    invalid_reasons: Counter = Counter()
    invalid_details = []  # Simpan detail error
    all_invalid_contracts = []  # Simpan kontrak yang invalid
    
    for i, (source, orig_filename, aug_type) in enumerate(augmented_contracts):
        if i % 200 == 0:
            logger.info(f"  Validating {i}/{len(augmented_contracts)}...")
        
        try:
            result = validate_contract(source, orig_filename)
            
            if result.is_valid:
                valid.append((source, orig_filename, aug_type))
                stats.total_valid += 1
            else:
                invalid_count += 1
                stats.total_invalid += 1
                
                # Kategorikan error
                if "brace" in result.error_message.lower():
                    invalid_reasons["brace_mismatch"] += 1
                elif "paren" in result.error_message.lower():
                    invalid_reasons["paren_mismatch"] += 1
                elif "type" in result.error_message.lower():
                    invalid_reasons["type_error"] += 1
                else:
                    invalid_reasons["other"] += 1
                
                # Simpan detail error untuk logging
                invalid_details.append({
                    "original_file": orig_filename,
                    "augmentation_type": aug_type,
                    "error_message": result.error_message,
                })
                
                # Simpan kontrak invalid untuk debug
                all_invalid_contracts.append((source, orig_filename, aug_type))
                    
        except Exception as e:
            if config.skip_validation_on_error:
                valid.append((source, orig_filename, aug_type))
            else:
                invalid_count += 1
                stats.total_invalid += 1
                error_msg = f"Validation exception: {str(e)}"
                invalid_details.append({
                    "original_file": orig_filename,
                    "augmentation_type": aug_type,
                    "error_message": error_msg,
                })
                all_invalid_contracts.append((source, orig_filename, aug_type))
            logger.warning(f"Validation error untuk {orig_filename}: {e}")
    
    logger.info(f"  Valid: {len(valid)}, Invalid: {invalid_count}")
    if invalid_reasons:
        logger.info(f"  Invalid breakdown: {dict(invalid_reasons)}")
    
    # Simpan error details ke JSON file
    if invalid_details:
        error_details_path = os.path.join(config.log_dir, "validation_errors.json")
        with open(error_details_path, "w", encoding="utf-8") as f:
            json.dump(invalid_details, f, indent=2, ensure_ascii=False)
        logger.info(f"  Error details saved to: {error_details_path}")
        
        # Create human-readable error report
        _save_error_report(invalid_details, config, logger)
        
        # Simpan invalid contracts untuk debugging
        _save_invalid_contracts(all_invalid_contracts, invalid_details, config, logger)
    
    return valid


# ─── Stage 6: Save output ────────────────────────────────────────────────────

def stage_save(
    valid_contracts: List[Tuple[str, str, str]],
    config: PipelineConfig,
    stats: AugmentationStats,
    logger: logging.Logger,
) -> List[str]:
    """
    Simpan semua kontrak valid ke output directory.
    """
    logger.info("=" * 60)
    logger.info("STAGE 6: Saving output")
    
    os.makedirs(config.output_dir, exist_ok=True)
    
    saved_paths = []
    counters: Dict[str, int] = {}
    
    for source, orig_filename, aug_type in valid_contracts:
        aug_key = aug_type.split("_")[0]  # "rename", "expr", "fheswap", "dead"
        counters[aug_key] = counters.get(aug_key, 0) + 1
        
        # Buat subdirectory per augmentation type
        subdir = os.path.join(config.output_dir, aug_key)
        os.makedirs(subdir, exist_ok=True)
        
        base_name = orig_filename.replace(".sol", "")
        idx = counters[aug_key]
        new_filename = f"{base_name}__{aug_type}_{idx:04d}.sol"
        output_path = os.path.join(subdir, new_filename)
        
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(source)
        
        saved_paths.append(output_path)
    
    logger.info(f"  Saved {len(saved_paths)} contracts to {config.output_dir}")
    for aug_key, count in sorted(counters.items()):
        logger.info(f"    {aug_key}: {count}")
    
    return saved_paths


# ─── Main pipeline ────────────────────────────────────────────────────────────

def run_pipeline(config: PipelineConfig) -> AugmentationStats:
    """
    Jalankan full augmentation pipeline.
    """
    logger = setup_logging(config.log_dir)
    stats = AugmentationStats()
    
    logger.info("╔══════════════════════════════════════════════════════════╗")
    logger.info("║       FHEVM Smart Contract Augmentation Pipeline         ║")
    logger.info("╚══════════════════════════════════════════════════════════╝")
    logger.info(f"Input dir:  {config.input_dir}")
    logger.info(f"Output dir: {config.output_dir}")
    
    # ── Step 1: Parse input contracts ──
    logger.info("\n[STEP 1] Parsing input contracts...")
    contracts = parse_all_contracts(config.input_dir)
    
    if not contracts:
        logger.error("Tidak ada kontrak yang berhasil di-parse!")
        return stats
    
    stats.total_input = len(contracts)
    
    # ── Step 2: Analyze class distribution ──
    logger.info("\n[STEP 2] Analyzing class distribution...")
    dist = get_class_distribution(contracts)
    stats.class_distribution_before = dist
    
    logger.info("  Distribusi kelas (sebelum augmentasi):")
    for cls, count in dist.items():
        bar = "█" * (count * 30 // max(dist.values()))
        logger.info(f"    {cls:20s} {count:4d}  {bar}")
    
    # Identify minority classes
    minority_classes = _get_minority_classes(dist)
    if minority_classes:
        logger.info(f"  Minority classes: {minority_classes}")
        logger.info(f"  Akan di-oversample dengan faktor {config.minority_oversample_factor}x")
    
    # ── Step 3: Apply transformations ──
    all_augmented: List[Tuple[str, str, str]] = []
    
    rename_results = stage_rename(contracts, config, stats, logger)
    all_augmented.extend(rename_results)
    
    expr_results = stage_expression(contracts, config, stats, logger)
    all_augmented.extend(expr_results)
    
    fhe_results = stage_fhe_swap(contracts, config, stats, logger)
    all_augmented.extend(fhe_results)
    
    dead_results = stage_dead_code(contracts, config, stats, logger)
    all_augmented.extend(dead_results)
    
    stats.total_generated = len(all_augmented)
    logger.info(f"\n[SUMMARY] Total generated: {stats.total_generated}")
    
    # ── Step 4: Validate ──
    valid_contracts = stage_validate(all_augmented, config, stats, logger)
    
    # ── Step 5: Save ──
    saved_paths = stage_save(valid_contracts, config, stats, logger)
    
    # ── Step 6: Final stats ──
    logger.info("\n" + "=" * 60)
    logger.info("FINAL STATISTICS")
    logger.info("=" * 60)
    logger.info(f"  Input contracts:       {stats.total_input}")
    logger.info(f"  Generated:             {stats.total_generated}")
    logger.info(f"  Valid (after filter):  {stats.total_valid if config.run_validation else stats.total_generated}")
    logger.info(f"  Invalid (filtered):    {stats.total_invalid}")
    logger.info(f"  Rename valid:          {stats.rename_generated}")
    logger.info(f"  Expression valid:      {stats.expression_generated}")
    logger.info(f"  FHE swap valid:        {stats.fhe_swap_generated}")
    logger.info(f"  Dead code valid:       {stats.dead_code_generated}")
    logger.info(f"  Total dataset size:    {stats.total_input + len(saved_paths)}")
    
    # Save stats to JSON
    stats_path = os.path.join(config.log_dir, "augmentation_stats.json")
    with open(stats_path, "w") as f:
        json.dump({
            "input": stats.total_input,
            "generated": stats.total_generated,
            "valid": len(saved_paths),
            "invalid": stats.total_invalid,
            "by_type": {
                "rename": stats.rename_generated,
                "expression": stats.expression_generated,
                "fhe_swap": stats.fhe_swap_generated,
                "dead_code": stats.dead_code_generated,
            },
            "class_distribution_before": stats.class_distribution_before,
        }, f, indent=2)
    
    logger.info(f"\n  Stats saved ke: {stats_path}")
    
    # Info tentang error report
    error_report = os.path.join(config.log_dir, "validation_errors.json")
    if os.path.exists(error_report):
        logger.info(f"  Error details saved ke: {error_report}")
    
    logger.info(f"  Output dir: {config.output_dir}")
    logger.info("  Pipeline selesai!")
    
    return stats


# ─── CLI entry point ──────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(
        description="FHEVM Smart Contract Augmentation Pipeline"
    )
    parser.add_argument("--input",   required=True,  help="Input directory berisi .sol files")
    parser.add_argument("--output",  required=True,  help="Output directory untuk hasil augmentasi")
    parser.add_argument("--logs",    default="./logs", help="Log directory")
    
    parser.add_argument("--target-rename",     type=int, default=10)
    parser.add_argument("--target-expression", type=int, default=10)
    parser.add_argument("--target-fhe-swap",   type=int, default=10)
    parser.add_argument("--target-dead-code",  type=int, default=10)
    
    parser.add_argument("--no-validation",  action="store_true", help="Skip compile validation")
    parser.add_argument("--fhe-strategy",   default="upcast_only",
                        choices=["upcast_only", "any_safe"])
    parser.add_argument("--minority-factor", type=float, default=2.0,
                        help="Oversample factor untuk minority classes")
    
    args = parser.parse_args()
    
    config = PipelineConfig(
        input_dir=args.input,
        output_dir=args.output,
        log_dir=args.logs,
        target_rename=args.target_rename,
        target_expression=args.target_expression,
        target_fhe_swap=args.target_fhe_swap,
        target_dead_code=args.target_dead_code,
        run_validation=not args.no_validation,
        fhe_swap_strategy=args.fhe_strategy,
        minority_oversample_factor=args.minority_factor,
    )
    
    run_pipeline(config)
