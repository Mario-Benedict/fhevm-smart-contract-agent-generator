"""
Copy train-split contracts from contracts/final/ to augmentation/contract_input/.

Usage (dari root project):
  python dataset/copy_train_contracts.py
  python dataset/copy_train_contracts.py --train dataset/split/train.csv
  python dataset/copy_train_contracts.py --src contracts/final --dest augmentation/contract_input
"""

import argparse
import shutil
import sys
from pathlib import Path

import pandas as pd


ROOT = Path(__file__).parent.parent  # root project


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Copy train contracts to augmentation folder")
    parser.add_argument("--train", default="dataset/split/train.csv",   help="Path ke train.csv")
    parser.add_argument("--src",   default="contracts/final",           help="Folder source .sol files")
    parser.add_argument("--dest",  default="augmentation/contract_input", help="Folder tujuan")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    train_csv = ROOT / args.train
    src_dir   = ROOT / args.src
    dest_dir  = ROOT / args.dest

    # Validasi
    if not train_csv.exists():
        sys.exit(f"ERROR: train.csv tidak ditemukan: {train_csv}")
    if not src_dir.exists():
        sys.exit(f"ERROR: folder source tidak ditemukan: {src_dir}")

    # Buat dest jika belum ada
    dest_dir.mkdir(parents=True, exist_ok=True)

    # Baca daftar file dari train.csv
    df = pd.read_csv(train_csv)
    if "file" not in df.columns:
        sys.exit("ERROR: kolom 'file' tidak ada di train.csv")

    filenames = df["file"].tolist()
    print(f"Train samples : {len(filenames)}")
    print(f"Source        : {src_dir}")
    print(f"Destination   : {dest_dir}")
    print()

    copied  = []
    missing = []

    for fname in filenames:
        src_file  = src_dir / fname
        dest_file = dest_dir / fname

        if not src_file.exists():
            missing.append(fname)
            continue

        shutil.copy2(src_file, dest_file)
        copied.append(fname)

    # Ringkasan
    print(f"Copied  : {len(copied)} file")
    if missing:
        print(f"Missing : {len(missing)} file")
        for f in missing:
            print(f"  - {f}")
    else:
        print("Missing : 0 file (semua berhasil dicopy)")

    print(f"\nSelesai. {len(copied)} contract tersimpan di: {dest_dir}")


if __name__ == "__main__":
    main()
