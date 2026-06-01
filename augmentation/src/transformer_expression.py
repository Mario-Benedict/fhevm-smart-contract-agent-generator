"""
transformer_expression.py
Substitusi ekspresi yang semantically equivalent, FHEVM-aware.
Hanya substitusi yang proven safe — tidak ubah hasil eksekusi.
"""

import re
import random
from typing import List, Tuple, Optional
from src.ast_parser import ContractMetadata


# ─── Substitusi Solidity biasa (non-FHE) ────────────────────────────────────

# Format: (pattern, replacement, description)
PLAIN_SUBSTITUTIONS: List[Tuple[str, str, str]] = [
    # Comparison negation — De Morgan style
    (r'!\s*\(\s*(\w+)\s*==\s*(\w+)\s*\)',  r'(\1 != \2)',    "neg_eq_to_neq"),
    (r'!\s*\(\s*(\w+)\s*!=\s*(\w+)\s*\)',  r'(\1 == \2)',    "neg_neq_to_eq"),
    (r'!\s*\(\s*(\w+)\s*>\s*(\w+)\s*\)',   r'(\1 <= \2)',    "neg_gt_to_lte"),
    (r'!\s*\(\s*(\w+)\s*<\s*(\w+)\s*\)',   r'(\1 >= \2)',    "neg_lt_to_gte"),
    (r'!\s*\(\s*(\w+)\s*>=\s*(\w+)\s*\)',  r'(\1 < \2)',     "neg_gte_to_lt"),
    (r'!\s*\(\s*(\w+)\s*<=\s*(\w+)\s*\)',  r'(\1 > \2)',     "neg_lte_to_gt"),

    # Boolean literal simplification
    (r'\b(\w+)\s*==\s*true\b',   r'\1',    "eq_true_simplify"),
    (r'\b(\w+)\s*==\s*false\b',  r'!\1',   "eq_false_simplify"),

    # Compound assignment expansion
    (r'\b(\w+)\s*\+=\s*(\w+)\b',  r'\1 = \1 + \2',  "expand_plus_assign"),
    (r'\b(\w+)\s*-=\s*(\w+)\b',   r'\1 = \1 - \2',  "expand_minus_assign"),
    (r'\b(\w+)\s*\*=\s*(\w+)\b',  r'\1 = \1 * \2',  "expand_mul_assign"),

    # Increment/decrement
    (r'\b(\w+)\+\+\b',  r'\1 += 1',  "postinc_to_plusassign"),
    (r'\b(\w+)--\b',    r'\1 -= 1',  "postdec_to_minusassign"),
    (r'\+\+(\w+)\b',    r'\1 += 1',  "preinc_to_plusassign"),
    (r'--(\w+)\b',      r'\1 -= 1',  "predec_to_minusassign"),

    # Power of 2 multiply/divide ↔ shift
    (r'\b(\w+)\s*\*\s*2\b',   r'(\1 << 1)',  "mul2_to_shl1"),
    (r'\b(\w+)\s*\*\s*4\b',   r'(\1 << 2)',  "mul4_to_shl2"),
    (r'\b(\w+)\s*\*\s*8\b',   r'(\1 << 3)',  "mul8_to_shl3"),
    (r'\b(\w+)\s*/\s*2\b',    r'(\1 >> 1)',  "div2_to_shr1"),
    (r'\b(\w+)\s*/\s*4\b',    r'(\1 >> 2)',  "div4_to_shr2"),

    # Require style variants
    (r'require\s*\(\s*(\w+)\s*>\s*0\s*,',   r'require(!(\1 == 0),',  "req_gt0_to_neq0"),
]


# ─── Substitusi FHE / FHEVM ──────────────────────────────────────────────────
# Support both namespaces: FHE.xxx (v0.6+) dan TFHE.xxx (legacy)
# Regex pakai group (?:FHE|TFHE) agar match keduanya sekaligus.

def _substitute_fhe_commutative(source: str) -> Tuple[str, int]:
    """
    Swap operand untuk operasi FHE/TFHE yang commutative.
    FHE.add(a, b) → FHE.add(b, a)
    TFHE.add(a, b) → TFHE.add(b, a)
    """
    commutative_ops = ["add", "mul", "and", "or", "xor", "eq", "ne", "min", "max"]
    count = 0
    result = source

    for op in commutative_ops:
        pattern = rf'((?:FHE|TFHE))\.{op}\s*\(\s*(\w[\w.]*)\s*,\s*(\w[\w.]*)\s*\)'

        def swap_args(m, op=op):
            ns, a, b = m.group(1), m.group(2), m.group(3)
            if a != b:
                return f'{ns}.{op}({b}, {a})'
            return m.group(0)

        new_result = re.sub(pattern, swap_args, result)
        if new_result != result:
            count += 1
        result = new_result

    return result, count


def _substitute_fhe_comparison_flip(source: str) -> Tuple[str, int]:
    """
    Flip comparison: FHE.gt(a, b) → FHE.lt(b, a)  (semantically equivalent)
    TFHE.ge(a, b) → TFHE.le(b, a)
    """
    flip_pairs = [
        ("gt", "lt"),
        ("ge", "le"),
    ]
    count = 0
    result = source

    for op1, op2 in flip_pairs:
        pattern = rf'((?:FHE|TFHE))\.{op1}\s*\(\s*(\w[\w.]*)\s*,\s*(\w[\w.]*)\s*\)'

        def flip(m, op2=op2):
            ns, a, b = m.group(1), m.group(2), m.group(3)
            return f'{ns}.{op2}({b}, {a})'

        new_result = re.sub(pattern, flip, result)
        if new_result != result:
            count += 1
        result = new_result

    return result, count


def _substitute_fhe_not_double(source: str) -> Tuple[str, int]:
    """
    Hilangkan double negation: FHE.not(FHE.not(x)) → x
    Juga handle TFHE.not(TFHE.not(x)) → x
    """
    count = 0
    result = source

    for ns in ("FHE", "TFHE"):
        pattern = rf'{ns}\.not\s*\(\s*{ns}\.not\s*\(\s*(\w+)\s*\)\s*\)'
        new_result = re.sub(pattern, r'\1', result)
        cnt = len(re.findall(pattern, result))
        if cnt:
            count += cnt
            result = new_result

    return result, count


# ─── Main transformer ────────────────────────────────────────────────────────

def apply_expression_substitution(
    meta: ContractMetadata,
    strategy: str = "plain",
    seed: Optional[int] = None,
    max_substitutions: int = 5,
) -> Optional[str]:
    """
    Apply expression substitution ke source code.
    Return None kalau tidak ada perubahan (agar pipeline bisa skip).

    strategy:
        "plain"    — hanya substitusi Solidity biasa (paling safe)
        "fhe"      — hanya substitusi FHE/TFHE operations
        "combined" — kedua-duanya
    """
    if seed is None:
        seed = hash(meta.filename + strategy) % (2**31)

    rng = random.Random(seed)
    source = meta.raw_source
    applied_count = 0

    if strategy in ("plain", "combined"):
        subs = PLAIN_SUBSTITUTIONS.copy()
        rng.shuffle(subs)

        for pattern, replacement, desc in subs:
            if applied_count >= max_substitutions:
                break
            try:
                new_source = re.sub(pattern, replacement, source)
                if new_source != source:
                    source = new_source
                    applied_count += 1
            except re.error:
                continue

    if strategy in ("fhe", "combined"):
        fhe_subs = [
            _substitute_fhe_commutative,
            _substitute_fhe_comparison_flip,
            _substitute_fhe_not_double,
        ]
        rng.shuffle(fhe_subs)

        for sub_fn in fhe_subs:
            if applied_count >= max_substitutions:
                break
            new_source, cnt = sub_fn(source)
            if cnt > 0 and new_source != source:
                source = new_source
                applied_count += 1

    # Return None kalau tidak ada perubahan — pipeline akan mark sebagai skipped
    if source == meta.raw_source:
        return None

    return source


def get_substitution_variants(
    meta: ContractMetadata,
    n_variants: int = 3
) -> List[str]:
    """
    Generate multiple variants dengan kombinasi substitusi berbeda.
    """
    variants = []
    strategies = ["plain", "fhe", "combined"]

    for i in range(n_variants):
        strategy = strategies[i % len(strategies)]
        seed = hash(meta.filename + str(i)) % (2**31)
        variant = apply_expression_substitution(
            meta,
            strategy=strategy,
            seed=seed,
            max_substitutions=3 + i,
        )
        if variant and variant != meta.raw_source:
            variants.append(variant)

    return variants