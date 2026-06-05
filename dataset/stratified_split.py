"""
Multilabel stratified split for final_labels.csv.

Strategy: group-by-combination — setiap unique kombinasi label
dipisah secara independen sesuai ratio. Jika kombinasi [1,1,1] ada 100
sampel dan ratio 80:20, maka tepat 80 masuk train dan 20 masuk test.
Sisa pembulatan dialokasikan ke split terbesar (train).

Usage:
  python stratified_split.py --train 0.7 --val 0.15 --test 0.15
  python stratified_split.py --train 0.8 --test 0.2
  python stratified_split.py --train 0.7 --val 0.15 --test 0.15 --seed 42 --output-dir splits/
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Multilabel stratified split — exact per-combination ratio"
    )
    parser.add_argument("--input", default="final_labels.csv", help="Path to CSV file")
    parser.add_argument("--train", type=float, required=True, help="Train ratio, e.g. 0.7")
    parser.add_argument("--val",   type=float, default=0.0,   help="Validation ratio, e.g. 0.15; omit for train/test only")
    parser.add_argument("--test",  type=float, required=True, help="Test ratio, e.g. 0.15 or 0.2")
    parser.add_argument("--seed",  type=int,   default=42,    help="Random seed")
    parser.add_argument("--output-dir", default=".", help="Directory to write split CSVs")
    return parser.parse_args()


def check_ratios(train: float, val: float, test: float) -> None:
    total = round(train + val + test, 6)
    if abs(total - 1.0) > 1e-4:
        sys.exit(f"ERROR: Ratios must sum to 1.0, got {total:.4f}")
    if any(r < 0 for r in (train, val, test)):
        sys.exit("ERROR: All ratios must be non-negative")


def load_data(csv_path: Path) -> tuple[pd.DataFrame, list[str]]:
    df = pd.read_csv(csv_path)
    non_label_cols = {"id", "file"}
    label_cols = [c for c in df.columns if c not in non_label_cols]
    if not label_cols:
        sys.exit("ERROR: No label columns found in CSV")
    return df, label_cols


def split_group(indices: np.ndarray, ratios: list[float], rng: np.random.Generator) -> list[np.ndarray]:
    """
    Split indices into len(ratios) parts, exactly proportional.
    Rounding remainder goes to the first (largest) split.
    """
    rng.shuffle(indices)
    n = len(indices)
    sizes = [int(r * n) for r in ratios]
    # Distribute rounding remainder to train (index 0)
    sizes[0] += n - sum(sizes)

    result = []
    start = 0
    for size in sizes:
        result.append(indices[start:start + size])
        start += size
    return result


def stratified_split(
    df: pd.DataFrame,
    label_cols: list[str],
    train_ratio: float,
    val_ratio: float,
    test_ratio: float,
    seed: int,
) -> tuple[pd.DataFrame, pd.DataFrame | None, pd.DataFrame]:
    rng = np.random.default_rng(seed)

    has_val = val_ratio > 0.0
    ratios = [train_ratio, val_ratio, test_ratio] if has_val else [train_ratio, test_ratio]

    # Group by exact label combination
    combo_col = df[label_cols].astype(str).agg("-".join, axis=1)
    groups = combo_col.groupby(combo_col).groups  # {combo: Index}

    parts: list[list[np.ndarray]] = [[] for _ in ratios]

    for combo, idx in groups.items():
        indices = np.array(idx)
        splits = split_group(indices, ratios, rng)
        for i, split in enumerate(splits):
            parts[i].append(split)

    split_dfs = []
    for part in parts:
        all_idx = np.concatenate(part) if part else np.array([], dtype=int)
        split_dfs.append(df.iloc[all_idx].reset_index(drop=True))

    if has_val:
        return split_dfs[0], split_dfs[1], split_dfs[2]
    else:
        return split_dfs[0], None, split_dfs[1]


def print_distribution(name: str, df: pd.DataFrame, label_cols: list[str], full_df: pd.DataFrame) -> None:
    n = len(df)
    n_full = len(full_df)
    print(f"\n{'='*55}")
    print(f"  {name}  ({n} samples / {100*n/n_full:.1f}% of total)")
    print(f"{'='*55}")

    print(f"  {'Label':<40} {'pos':>5}  {'%':>6}")
    print(f"  {'-'*40}  {'-----'}  {'------'}")
    for col in label_cols:
        pos = df[col].sum()
        pct = 100 * pos / n if n > 0 else 0
        print(f"  {col:<40} {pos:>5}  {pct:>5.1f}%")

    combo_col = df[label_cols].astype(str).agg("-".join, axis=1)
    full_combo = full_df[label_cols].astype(str).agg("-".join, axis=1)
    combos_full = full_combo.value_counts().sort_index()
    combos_split = combo_col.value_counts().sort_index()

    print(f"\n  {'Combination':<30} {'full':>6}  {'split':>6}  {'split%':>7}  {'expected%':>9}")
    print(f"  {'-'*30}  {'------'}  {'------'}  {'-------'}  {'---------'}")
    for combo in combos_full.index:
        full_count  = combos_full.get(combo, 0)
        split_count = combos_split.get(combo, 0)
        split_pct   = 100 * split_count / full_count if full_count > 0 else 0
        expected_pct = 100 * n / n_full
        print(f"  [{combo}]  {full_count:>6}  {split_count:>6}  {split_pct:>6.1f}%  {expected_pct:>8.1f}%")


def main() -> None:
    args = parse_args()
    check_ratios(args.train, args.val, args.test)

    input_path = Path(args.input)
    if not input_path.is_absolute():
        input_path = Path(__file__).parent / input_path
    if not input_path.exists():
        sys.exit(f"ERROR: File not found: {input_path}")

    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = Path(__file__).parent / output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    df, label_cols = load_data(input_path)

    has_val = args.val > 0.0
    ratio_str = f"{args.train}/{args.val}/{args.test}" if has_val else f"{args.train}/{args.test}"
    print(f"Input   : {input_path.name}  ({len(df)} samples, {len(label_cols)} labels)")
    print(f"Ratios  : {ratio_str}  (seed={args.seed})")
    print(f"Labels  : {label_cols}")

    df_train, df_val, df_test = stratified_split(
        df, label_cols, args.train, args.val, args.test, args.seed
    )

    print_distribution("TRAIN",      df_train, label_cols, df)
    if df_val is not None:
        print_distribution("VALIDATION", df_val,   label_cols, df)
    print_distribution("TEST",       df_test,  label_cols, df)

    df_train.to_csv(output_dir / "train.csv", index=False)
    df_test.to_csv(output_dir / "test.csv",   index=False)
    if df_val is not None:
        df_val.to_csv(output_dir / "val.csv", index=False)

    print(f"\nSaved to: {output_dir}/")
    sizes = {"train": len(df_train), "test": len(df_test)}
    if df_val is not None:
        sizes["val"] = len(df_val)
    for name, size in sizes.items():
        print(f"  {name}.csv  =>  {size} rows")


if __name__ == "__main__":
    main()
