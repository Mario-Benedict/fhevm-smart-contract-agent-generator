"""
ast_parser.py
Regex + structural parser untuk Solidity/FHEVM contracts.
Ekstrak metadata: tipe FHE, variabel, fungsi, ekspresi, label kelas.
"""

import re
import os
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple


# ─── FHEVM type registry ────────────────────────────────────────────────────
FHE_INT_TYPES = ["euint8", "euint16", "euint32", "euint64", "euint128", "euint256"]
FHE_ALL_TYPES = FHE_INT_TYPES + ["ebool", "eaddress", "ebytes32", "ebytes64", "ebytes128", "ebytes256"]
FHE_EXTERNAL_TYPES = ["externalEbool", "externalEaddress", "externalEuint8", "externalEuint16", 
                      "externalEuint32", "externalEuint64", "externalEuint128", "externalEuint256",
                      "externalEbytes32", "externalEbytes64", "externalEbytes128", "externalEbytes256"]
ALL_TYPES_WITH_EXTERNAL = FHE_ALL_TYPES + FHE_EXTERNAL_TYPES

FHE_TYPE_HIERARCHY = {t: i for i, t in enumerate(FHE_INT_TYPES)}

# Operasi TFHE yang commutative (aman di-swap operandnya)
TFHE_COMMUTATIVE_OPS = {"add", "mul", "and", "or", "xor", "eq", "ne", "min", "max"}

# Operasi TFHE yang punya pasangan flip (gt ↔ lt, gte ↔ lte)
TFHE_FLIP_PAIRS = {
    "gt": "lt", "lt": "gt",
    "ge": "le", "le": "ge",
    "gte": "lte", "lte": "gte",
}

# Operasi yang TIDAK boleh di-swap (non-commutative)
TFHE_NON_COMMUTATIVE = {"sub", "div", "rem", "shl", "shr", "rotl", "rotr"}


@dataclass
class ContractMetadata:
    filepath: str
    filename: str
    raw_source: str
    
    # Struktur
    contract_name: str = ""
    pragma_line: str = ""
    imports: List[str] = field(default_factory=list)
    
    # FHE-specific
    fhe_types_used: List[str] = field(default_factory=list)       # tipe FHE yang dipakai
    fhe_vars: List[Tuple[str, str]] = field(default_factory=list)  # (type, varname)
    fhe_operations: List[str] = field(default_factory=list)        # TFHE.xxx calls
    
    # Variabel & fungsi
    state_vars: List[Tuple[str, str]] = field(default_factory=list)  # (type, name)
    functions: List[str] = field(default_factory=list)
    local_vars: List[Tuple[str, str]] = field(default_factory=list)
    
    # Ekspresi yang bisa disubstitusi
    arithmetic_exprs: List[str] = field(default_factory=list)
    comparison_exprs: List[str] = field(default_factory=list)
    
    # Label untuk class balance analysis
    contract_class: str = "unknown"
    complexity_score: int = 0
    
    # Augmentasi tracking
    augmentation_history: List[str] = field(default_factory=list)


def parse_contract(filepath: str) -> Optional[ContractMetadata]:
    """Parse satu file Solidity dan return metadata-nya."""
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            source = f.read()
    except Exception as e:
        print(f"[WARN] Gagal baca {filepath}: {e}")
        return None

    meta = ContractMetadata(
        filepath=filepath,
        filename=os.path.basename(filepath),
        raw_source=source,
    )

    _extract_pragma(meta, source)
    _extract_imports(meta, source)
    _extract_contract_name(meta, source)
    _extract_fhe_types(meta, source)
    _extract_fhe_vars(meta, source)
    _extract_fhe_operations(meta, source)
    _extract_state_vars(meta, source)
    _extract_functions(meta, source)
    _extract_local_vars(meta, source)
    _classify_contract(meta, source)
    _compute_complexity(meta, source)

    return meta


# ─── Extractor helpers ───────────────────────────────────────────────────────

def _extract_pragma(meta: ContractMetadata, src: str):
    m = re.search(r"pragma\s+solidity\s+[^;]+;", src)
    if m:
        meta.pragma_line = m.group(0)


def _extract_imports(meta: ContractMetadata, src: str):
    meta.imports = re.findall(r'import\s+[^;]+;', src)


def _extract_contract_name(meta: ContractMetadata, src: str):
    m = re.search(r'\bcontract\s+(\w+)', src)
    if m:
        meta.contract_name = m.group(1)


def _extract_fhe_types(meta: ContractMetadata, src: str):
    found = set()
    for t in ALL_TYPES_WITH_EXTERNAL:
        if re.search(r'\b' + re.escape(t) + r'\b', src):
            found.add(t)
    meta.fhe_types_used = sorted(found)


def _extract_fhe_vars(meta: ContractMetadata, src: str):
    """Ekstrak deklarasi variabel FHE: tipe + nama."""
    pattern = r'\b(' + '|'.join(re.escape(t) for t in ALL_TYPES_WITH_EXTERNAL) + r')\s+(?:private|public|internal|external)?\s*(\w+)\s*[;=]'
    matches = re.findall(pattern, src)
    meta.fhe_vars = [(t, n) for t, n in matches if n not in ('returns', 'memory', 'storage', 'calldata')]


def _extract_fhe_operations(meta: ContractMetadata, src: str):
    ops = re.findall(r'TFHE\.(\w+)\s*\(', src)
    meta.fhe_operations = list(set(ops))


def _extract_state_vars(meta: ContractMetadata, src: str):
    """Ekstrak state variable (tipe Solidity biasa + FHE)."""
    solidity_types = r'(?:uint\d*|int\d*|bool|address|bytes\d*|string|mapping|' + \
                     '|'.join(re.escape(t) for t in ALL_TYPES_WITH_EXTERNAL) + r')'
    pattern = rf'\b({solidity_types})\s+(?:private|public|internal|constant|immutable|\s)*\s*(\w+)\s*[;=]'
    matches = re.findall(pattern, src)
    meta.state_vars = [(t, n) for t, n in matches 
                       if n not in ('returns', 'memory', 'storage', 'calldata', 'indexed')]


def _extract_functions(meta: ContractMetadata, src: str):
    meta.functions = re.findall(r'\bfunction\s+(\w+)\s*\(', src)


def _extract_local_vars(meta: ContractMetadata, src: str):
    """Ekstrak variabel lokal di dalam fungsi."""
    solidity_types = r'(?:uint\d*|int\d*|bool|address|bytes\d*|string|' + \
                     '|'.join(re.escape(t) for t in ALL_TYPES_WITH_EXTERNAL) + r')'
    pattern = rf'(?:^|\s)({solidity_types})\s+(\w+)\s*='
    matches = re.findall(pattern, src, re.MULTILINE)
    meta.local_vars = [(t, n) for t, n in matches 
                       if n not in ('returns', 'memory', 'storage')]


def _classify_contract(meta: ContractMetadata, src: str):
    """
    Klasifikasi kontrak berdasarkan pola yang ditemukan.
    Ini dipakai untuk identifikasi skewness antar kelas.
    """
    src_lower = src.lower()
    
    # Cek pola utama
    has_transfer   = bool(re.search(r'\btransfer\b|\bbalance\b|\btoken\b', src_lower))
    has_voting     = bool(re.search(r'\bvot\w+\b|\bproposal\b|\bellot\b', src_lower))
    has_auction    = bool(re.search(r'\bauction\b|\bbid\b|\bhighest\b', src_lower))
    has_access     = bool(re.search(r'\baccess\b|\bpermission\b|\ballow\b|\bwhitelist\b', src_lower))
    has_escrow     = bool(re.search(r'\bescrow\b|\bdeposit\b|\bwithdraw\b', src_lower))
    has_game       = bool(re.search(r'\bgame\b|\bplayer\b|\bscore\b|\bwin\b', src_lower))
    has_identity   = bool(re.search(r'\bidentity\b|\bkyc\b|\bverif\w+\b', src_lower))
    has_oracle     = bool(re.search(r'\boracle\b|\bprice\b|\bfeed\b', src_lower))

    if has_voting:
        meta.contract_class = "voting"
    elif has_auction:
        meta.contract_class = "auction"
    elif has_transfer:
        meta.contract_class = "token_transfer"
    elif has_escrow:
        meta.contract_class = "escrow"
    elif has_game:
        meta.contract_class = "game"
    elif has_identity:
        meta.contract_class = "identity"
    elif has_oracle:
        meta.contract_class = "oracle"
    elif has_access:
        meta.contract_class = "access_control"
    else:
        meta.contract_class = "generic"


def _compute_complexity(meta: ContractMetadata, src: str):
    """Hitung complexity score sederhana untuk stratifikasi augmentasi."""
    score = 0
    score += len(meta.functions) * 3
    score += len(meta.fhe_vars) * 5          # FHE vars lebih complex
    score += len(meta.fhe_operations) * 2
    score += src.count("for ") * 4
    score += src.count("while ") * 4
    score += src.count("if ") * 2
    score += src.count("mapping") * 3
    score += src.count("modifier") * 2
    meta.complexity_score = score


def parse_all_contracts(input_dir: str) -> List[ContractMetadata]:
    """Parse semua .sol files dari direktori."""
    contracts = []
    sol_files = [f for f in os.listdir(input_dir) if f.endswith(".sol")]
    
    print(f"[INFO] Menemukan {len(sol_files)} file .sol di {input_dir}")
    
    for fname in sol_files:
        fpath = os.path.join(input_dir, fname)
        meta = parse_contract(fpath)
        if meta:
            contracts.append(meta)
    
    print(f"[INFO] Berhasil parse {len(contracts)} kontrak")
    return contracts


def get_class_distribution(contracts: List[ContractMetadata]) -> Dict[str, int]:
    """Return distribusi kelas untuk analisis skewness."""
    dist: Dict[str, int] = {}
    for c in contracts:
        dist[c.contract_class] = dist.get(c.contract_class, 0) + 1
    return dict(sorted(dist.items(), key=lambda x: x[1], reverse=True))
