"""
transformer_dead_code.py
Dead Code Injection: tambah kode yang unreachable / tidak berpengaruh.
Semua injeksi dijamin tidak mengubah state atau hasil fungsi.
FHEVM-aware: tidak inject code yang bisa trigger FHE operations secara tidak sengaja.
"""

import re
import random
from typing import List, Optional, Tuple
from src.ast_parser import ContractMetadata


# ─── Template dead code yang safe ────────────────────────────────────────────

# Comment blocks (paling safe, tidak mempengaruhi compile)
COMMENT_TEMPLATES = [
    "// Cache value for gas optimization",
    "// Validate input constraints", 
    "// FHE operation: encrypted computation",
    "// Security check: access control validation",
    "// State update: persist to storage",
    "// Event emission: notify off-chain listeners",
    "// Gas optimization: avoid redundant SLOAD",
    "// Invariant: ensure state consistency",
]

# Emit events dummy (hanya kalau event sudah ada — skip kalau tidak ada)
# Lebih aman: hanya tambah comment

# Unreachable require yang selalu pass
UNREACHABLE_REQUIRE_TEMPLATES = [
    "require(true, \"unreachable\");",
    "require(1 == 1, \"invariant\");",
    "require(address(this) != address(0), \"valid contract\");",
]

# Local variable yang dideklarasi tapi tidak dipakai (dead store)
# HATI-HATI: beberapa compiler warning untuk unused vars
# Gunakan dengan prefix underscore sesuai convention Solidity
DEAD_VAR_TEMPLATES = [
    "uint256 _unused = 0;",
    "bool _flag = false;",
    "uint256 _gasStart = gasleft();",  # gasleft() call — tidak ubah state
]

# Kondisi yang selalu false (unreachable branch)
DEAD_BRANCH_TEMPLATES = [
    ("if (false) {", "revert(\"unreachable\");", "}"),
    ("if (1 == 2) {", "revert(\"dead branch\");", "}"),
    ("if (address(0) == address(this)) {", "revert(\"impossible\");", "}"),
]


def _find_function_bodies(source: str) -> List[Tuple[int, int]]:
    """
    Temukan posisi awal dan akhir function body { ... }.
    Return list of (start, end) positions.
    Dalam Solidity: contract body = depth 1, function bodies = depth 2.
    """
    bodies = []
    depth = 0
    brace_stack = []  # stack of (position, context_type)
    
    i = 0
    while i < len(source):
        # Skip string literals
        if source[i] in ('"', "'"):
            quote = source[i]
            i += 1
            while i < len(source) and source[i] != quote:
                if source[i] == '\\':
                    i += 1
                i += 1
            i += 1
            continue
        
        # Skip single-line comments
        if source[i:i+2] == "//":
            while i < len(source) and source[i] != '\n':
                i += 1
            continue
        
        # Skip multi-line comments
        if source[i:i+2] == "/*":
            i += 2
            while i < len(source) - 1 and source[i:i+2] != "*/":
                i += 1
            i += 2
            continue
        
        if source[i] == '{':
            depth += 1
            # Cek context sebelum brace ini
            pre_brace = source[max(0, i-200):i]
            # Cari keyword terakhir sebelum brace
            last_func = [(m.start(), 'function') for m in re.finditer(r'\bfunction\s+\w+[^{]*$', pre_brace)]
            last_contract = [(m.start(), 'contract') for m in re.finditer(r'\b(?:contract|library|interface)\s+\w+[^{]*$', pre_brace)]
            
            all_markers = last_func + last_contract
            if all_markers:
                _, ctx_type = max(all_markers, key=lambda x: x[0])
            else:
                ctx_type = 'other'
            
            brace_stack.append((i, ctx_type, depth))
        
        elif source[i] == '}':
            if brace_stack:
                open_pos, ctx_type, open_depth = brace_stack.pop()
                if ctx_type == 'function':
                    bodies.append((open_pos + 1, i))
            depth -= 1
        
        i += 1
    
    return bodies


def _inject_comment(source: str, rng: random.Random) -> str:
    """Inject comment di dalam function body."""
    bodies = _find_function_bodies(source)
    if not bodies:
        return source
    
    # Pilih function body secara random
    start, end = rng.choice(bodies)
    body = source[start:end]
    
    # Temukan posisi setelah newline pertama di dalam body
    nl_pos = body.find('\n')
    if nl_pos < 0:
        return source
    
    comment = rng.choice(COMMENT_TEMPLATES)
    indent = _detect_indent(body, nl_pos)
    
    insert_pos = start + nl_pos + 1
    injection = f"{indent}{comment}\n"
    
    return source[:insert_pos] + injection + source[insert_pos:]


def _inject_unreachable_require(source: str, rng: random.Random) -> str:
    """
    Inject require statement yang selalu true.
    SAFER: Hanya inject simple require(true) to minimize syntax errors
    """
    bodies = _find_function_bodies(source)
    if not bodies:
        return source
    
    start, end = rng.choice(bodies)
    body = source[start:end]
    
    nl_pos = body.find('\n')
    if nl_pos < 0:
        return source
    
    # Use simplest form: require(true, "OK");
    # This has minimal chance of breaking syntax
    template = "require(true);"
    indent = _detect_indent(body, nl_pos)
    
    insert_pos = start + nl_pos + 1
    injection = f"{indent}{template}\n"
    
    return source[:insert_pos] + injection + source[insert_pos:]


def _inject_dead_branch(source: str, rng: random.Random) -> str:
    """
    Inject if(false) { revert() } yang tidak pernah dieksekusi.
    SAFER: Hanya inject comment daripada actual code to avoid syntax errors
    """
    bodies = _find_function_bodies(source)
    if not bodies:
        return source
    
    # Instead of injecting code, just inject comment
    # This is safer and avoids syntax errors
    return _inject_comment(source, rng)


def _inject_dead_local_var(source: str, rng: random.Random) -> str:
    """
    Inject deklarasi variabel lokal yang tidak dipakai.
    Gunakan underscore prefix untuk avoid Solidity warning.
    """
    bodies = _find_function_bodies(source)
    if not bodies:
        return source
    
    start, end = rng.choice(bodies)
    body = source[start:end]
    
    nl_pos = body.find('\n')
    if nl_pos < 0:
        return source
    
    template = rng.choice(DEAD_VAR_TEMPLATES)
    indent = _detect_indent(body, nl_pos)
    
    insert_pos = start + nl_pos + 1
    injection = f"{indent}{template}\n"
    
    return source[:insert_pos] + injection + source[insert_pos:]


def _detect_indent(body: str, after_pos: int) -> str:
    """Detect indentation level dari teks di sekitar posisi."""
    # Cari baris berikutnya dan ambil whitespace-nya
    next_nl = body.find('\n', after_pos + 1)
    if next_nl < 0:
        return "        "  # default 8 spaces
    
    next_line_start = after_pos + 1
    next_line = body[next_line_start:next_nl]
    indent = len(next_line) - len(next_line.lstrip())
    return " " * max(indent, 8)


# ─── Main transformer ────────────────────────────────────────────────────────

# Injection strategies dengan tingkat risiko
INJECTION_STRATEGIES = [
    ("comment", _inject_comment, 1.0),              # paling safe
    ("unreachable_require", _inject_unreachable_require, 0.8),  # safe
    ("dead_branch", _inject_dead_branch, 0.6),       # moderate
    ("dead_local_var", _inject_dead_local_var, 0.4), # ada unused var warning
]


def apply_dead_code_injection(
    meta: ContractMetadata,
    n_injections: int = 2,
    strategies: Optional[List[str]] = None,
    seed: Optional[int] = None,
) -> str:
    """
    Apply dead code injection ke source.
    
    n_injections: berapa kali injeksi (default 2 — cukup untuk diversifikasi)
    strategies: list strategy yang boleh dipakai. None = auto pilih berdasarkan safety
    """
    if seed is None:
        seed = hash(meta.filename + "dead") % (2**31)
    
    rng = random.Random(seed)
    source = meta.raw_source
    
    # Filter strategies
    available = [(name, fn, weight) for name, fn, weight in INJECTION_STRATEGIES
                 if strategies is None or name in strategies]
    
    # Sort by safety weight
    available.sort(key=lambda x: x[2], reverse=True)
    
    for i in range(n_injections):
        if not available:
            break
        
        # Pilih strategy dengan weighted random
        weights = [w for _, _, w in available]
        total = sum(weights)
        r = rng.random() * total
        
        chosen_fn = available[0][1]  # default ke paling safe
        cumulative = 0
        for name, fn, weight in available:
            cumulative += weight
            if r <= cumulative:
                chosen_fn = fn
                break
        
        try:
            new_source = chosen_fn(source, rng)
            if new_source and len(new_source) > len(source):
                source = new_source
        except Exception as e:
            # Kalau gagal, skip dan lanjut
            continue
    
    return source


def get_dead_code_variants(
    meta: ContractMetadata,
    n_variants: int = 3,
) -> List[str]:
    """Generate multiple dead code injection variants."""
    variants = []
    
    strategy_sets = [
        ["comment"],
        ["comment", "unreachable_require"],
        ["comment", "dead_branch"],
        ["comment", "unreachable_require", "dead_branch"],
    ]
    
    for i in range(n_variants):
        strategies = strategy_sets[i % len(strategy_sets)]
        seed = hash(meta.filename + str(i) + "dead") % (2**31)
        
        result = apply_dead_code_injection(
            meta,
            n_injections=1 + (i % 2),
            strategies=strategies,
            seed=seed,
        )
        
        if result != meta.raw_source:
            variants.append(result)
    
    return variants
