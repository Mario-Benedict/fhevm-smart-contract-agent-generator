"""
transformer_fhe_types.py
FHE Type Swapping: ganti euint32 → euint64, dll.
FHEVM-aware: handle TFHE.asEuintX(), casting, dan ACL patterns.
"""

import re
import random
from typing import Dict, List, Optional, Set, Tuple
from src.ast_parser import ContractMetadata, FHE_INT_TYPES, FHE_TYPE_HIERARCHY


# ─── Aturan swap yang valid ──────────────────────────────────────────────────

# Hanya allow upcasting (aman dari overflow)
# Format: source_type → [candidate_target_types]
# FHEVM support: euint8, euint16, euint32, euint64 (bukan euint128, euint256)
SAFE_UPCAST_MAP: Dict[str, List[str]] = {
    "euint8":  ["euint16", "euint32", "euint64"],
    "euint16": ["euint32", "euint64"],
    "euint32": ["euint64"],
}

# Urutan tipe dari kecil ke besar (untuk normalisasi)
TYPE_ORDER = ["euint8", "euint16", "euint32", "euint64"]


# ─── Internal helpers ─────────────────────────────────────────────────────────

def _get_fhe_int_types_in_source(source: str) -> Set[str]:
    """Detect tipe FHE integer yang dipakai di source."""
    found = set()
    for t in FHE_INT_TYPES:
        if re.search(r'\b' + re.escape(t) + r'\b', source):
            found.add(t)
    return found


def _get_max_type(types: Set[str]) -> Optional[str]:
    """Return tipe tertinggi dari set tipe yang ada."""
    for t in reversed(TYPE_ORDER):
        if t in types:
            return t
    return None


def _normalize_to_max(source: str, present_types: Set[str]) -> Optional[str]:
    """
    Untuk kontrak mixed-type: normalkan semua tipe ke tipe tertinggi yang ada.
    Misal: {euint8, euint16, euint32} → semua jadi euint32.
    Return None jika tidak ada perubahan (sudah homogen atau tidak ada tipe valid).
    """
    max_type = _get_max_type(present_types)
    if max_type is None:
        return None

    # Kalau sudah homogen (cuma 1 tipe), skip — bukan tugas normalize
    if len(present_types) == 1:
        return None

    result = source
    changed = False

    # Swap semua tipe di bawah max_type → max_type, dari terkecil ke terbesar
    for t in TYPE_ORDER:
        if t == max_type or t not in present_types:
            continue
        new_result = _apply_type_swap(result, t, max_type)
        if new_result != result:
            changed = True
            result = new_result

    return result if changed else None


def _get_swap_candidates(source: str) -> List[Tuple[str, str]]:
    """
    Return list (old_type, new_type) yang bisa di-swap.

    Strategi dua tahap:
    1. Kalau mixed-type → normalize semua ke max (satu kandidat komposit).
       Ini direpresentasikan sebagai (NORMALIZE, max_type) — ditangani khusus
       di apply_fhe_type_swap / get_all_swap_variants.
    2. Kalau sudah homogen (satu tipe) → upcast ke target yang lebih besar.
       Skip jika new_type sudah ada di source.
    """
    present_types = _get_fhe_int_types_in_source(source)
    if not present_types:
        return []

    # Tahap 1: mixed → normalize
    if len(present_types) > 1:
        max_type = _get_max_type(present_types)
        if max_type:
            return [("__normalize__", max_type)]

    # Tahap 2: homogen → upcast biasa
    candidates: List[Tuple[str, str]] = []
    for old_type in sorted(present_types):
        if old_type not in SAFE_UPCAST_MAP:
            continue
        for new_type in SAFE_UPCAST_MAP[old_type]:
            if new_type in present_types:
                continue
            candidates.append((old_type, new_type))

    return candidates


def _apply_type_swap(source: str, old_type: str, new_type: str) -> str:
    """
    Apply type swap SEMUA occurrences secara consistent.
    Swap di:
      - Type declarations       : euint8 x;
      - externalEuintX params   : externalEuint8 encVal
      - FHE/TFHE functions      : FHE.asEuint8(...), TFHE.asEuint8(...), etc
      - Everywhere dengan word boundary
    """
    old_num = old_type.replace("euint", "")
    new_num = new_type.replace("euint", "")

    result = source

    # Pattern 1: externalEuintX — harus SEBELUM euintX agar tidak partial-match
    # externalEuint8 → externalEuint16, dst
    result = re.sub(
        r'\bexternalEuint' + re.escape(old_num) + r'\b',
        f"externalEuint{new_num}",
        result,
    )

    # Pattern 2: Tipe keyword euintX (declarations, assignments) dengan word boundary
    result = re.sub(r'\b' + re.escape(old_type) + r'\b', new_type, result)

    # Pattern 3: FHE/TFHE function replacements (both FHE dan TFHE)
    # Support: FHE.asEuint8(, TFHE.asEuint8(, FHE.randEuint8(, etc
    result = result.replace(f"FHE.asEuint{old_num}(", f"FHE.asEuint{new_num}(")
    result = result.replace(f"TFHE.asEuint{old_num}(", f"TFHE.asEuint{new_num}(")

    result = result.replace(f"FHE.randEuint{old_num}()", f"FHE.randEuint{new_num}()")
    result = result.replace(f"TFHE.randEuint{old_num}()", f"TFHE.randEuint{new_num}()")

    result = result.replace(f"FHE.randEuint{old_num}(", f"FHE.randEuint{new_num}(")
    result = result.replace(f"TFHE.randEuint{old_num}(", f"TFHE.randEuint{new_num}(")

    return result


def _validate_swap_safety(source: str, old_type: str, new_type: str) -> bool:
    """Cek apakah swap ini aman. Upcast selalu safe."""
    if old_type == "__normalize__":
        return True  # normalize ke max selalu safe (semua upcast)
    old_num = int(old_type.replace("euint", ""))
    new_num = int(new_type.replace("euint", ""))
    return new_num > old_num  # only upcast supported


# ─── Public API ───────────────────────────────────────────────────────────────

def apply_fhe_type_swap(
    meta: ContractMetadata,
    strategy: str = "upcast_only",
    seed: Optional[int] = None,
    swap_pair: Optional[Tuple[str, str]] = None,
) -> Optional[str]:
    """
    Apply FHE type swapping ke source code.
    Return None kalau tidak ada swap yang valid atau aman.

    Untuk mixed-type contracts: normalize semua ke max type dulu,
    baru bisa di-upcast di variant berikutnya.
    """
    source = meta.raw_source

    if seed is None:
        seed = hash(meta.filename + strategy) % (2**31)

    rng = random.Random(seed)

    if swap_pair is not None:
        candidates = [swap_pair]
    else:
        candidates = _get_swap_candidates(source)

    if not candidates:
        return None

    rng.shuffle(candidates)

    for old_type, new_type in candidates:
        if not _validate_swap_safety(source, old_type, new_type):
            continue

        if old_type == "__normalize__":
            present_types = _get_fhe_int_types_in_source(source)
            result = _normalize_to_max(source, present_types)
        else:
            result = _apply_type_swap(source, old_type, new_type)

        if result and result != source:
            return result

    return None


def get_all_swap_variants(meta: ContractMetadata) -> List[Tuple[str, str, str]]:
    """
    Generate semua variasi swap yang valid untuk satu kontrak.
    Return: list of (old_type, new_type, modified_source)

    Untuk mixed-type: hasilkan normalize-to-max sebagai variant pertama,
    lalu upcast dari max type sebagai variant berikutnya.
    """
    source = meta.raw_source
    variants = []

    candidates = _get_swap_candidates(source)

    for old_type, new_type in candidates:
        if not _validate_swap_safety(source, old_type, new_type):
            continue

        if old_type == "__normalize__":
            present_types = _get_fhe_int_types_in_source(source)
            result = _normalize_to_max(source, present_types)
            if result and result != source:
                # Label informatif: misal "euint8+euint16+euint32→euint32"
                lower_types = "+".join(
                    t for t in TYPE_ORDER
                    if t in present_types and t != new_type
                )
                label = f"{lower_types}→{new_type}"
                variants.append((label, new_type, result))

                # Bonus: upcast dari normalized result (hanya kalau sudah homogen)
                # Cek dulu apakah normalized result benar-benar homogen
                normalized_types = _get_fhe_int_types_in_source(result)
                if len(normalized_types) == 1 and new_type in normalized_types:
                    for upcast_target in SAFE_UPCAST_MAP.get(new_type, []):
                        upcasted = _apply_type_swap(result, new_type, upcast_target)
                        if upcasted and upcasted != result:
                            variants.append((new_type, upcast_target, upcasted))
        else:
            result = _apply_type_swap(source, old_type, new_type)
            if result and result != source:
                variants.append((old_type, new_type, result))

    return variants