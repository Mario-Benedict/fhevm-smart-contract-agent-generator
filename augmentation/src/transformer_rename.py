"""
transformer_rename.py
Transformasi paling aman: rename variabel lokal & parameter fungsi.
TIDAK rename: state variables, fungsi publik, event, error (bisa break ABI).
TIDAK rename: variabel FHE yang dipakai di TFHE.allow() calls.
"""

import re
import random
import string
from typing import Dict, List, Tuple, Set, Optional
from src.ast_parser import ContractMetadata, FHE_ALL_TYPES


# ─── Prefix pools untuk nama variabel baru ──────────────────────────────────
PREFIXES = [
    "val", "tmp", "res", "enc", "sec", "prv", "buf",
    "out", "inp", "aux", "ref", "ctx", "acc", "amt",
    "num", "ptr", "idx", "key", "dat", "obj",
]

SUFFIXES = ["_a", "_b", "_x", "_y", "_0", "_1", "_n", "_m", ""]

# Keyword Solidity yang tidak boleh di-rename
SOLIDITY_KEYWORDS = {
    "address", "bool", "string", "bytes", "mapping", "memory", "storage",
    "calldata", "public", "private", "internal", "external", "view", "pure",
    "payable", "returns", "return", "emit", "event", "error", "modifier",
    "require", "revert", "assert", "this", "msg", "block", "tx", "abi",
    "keccak256", "sha256", "ecrecover", "gasleft", "blockhash",
    "selfdestruct", "delegatecall", "staticcall", "call",
    "uint", "int", "uint8", "uint16", "uint32", "uint64", "uint128", "uint256",
    "int8", "int16", "int32", "int64", "int128", "int256",
    "true", "false", "wei", "gwei", "ether", "seconds", "minutes", "hours",
    "days", "weeks",
    # FHEVM keywords
    "TFHE", "euint8", "euint16", "euint32", "euint64", "euint128", "euint256",
    "ebool", "eaddress", "ebytes32", "ebytes64", "ebytes128", "ebytes256",
    "externalEbool", "externalEaddress", "externalEuint8", "externalEuint16",
    "externalEuint32", "externalEuint64", "externalEuint128", "externalEuint256",
    "externalEbytes32", "externalEbytes64", "externalEbytes128", "externalEbytes256",
    "FHEVMConfig", "SepoliaZamaFHEVMConfig", "Gateway",
}


def _generate_new_name(original: str, seed: int, strategy: int = 0) -> str:
    """Generate nama variabel baru berdasarkan strategi."""
    rng = random.Random(seed)
    
    if strategy == 0:
        # Prefix + counter
        prefix = rng.choice(PREFIXES)
        suffix = rng.choice(SUFFIXES)
        return f"{prefix}{suffix}"
    
    elif strategy == 1:
        # Preserve prefix, ganti suffix
        # misal: encryptedBalance → encryptedAmt
        if len(original) > 3:
            return original[:3] + "_" + rng.choice(PREFIXES)
        return rng.choice(PREFIXES) + str(rng.randint(0, 99))
    
    elif strategy == 2:
        # Random tapi readable: consonant+vowel pattern
        consonants = "bcdfghjklmnprstvwxyz"
        vowels = "aeiou"
        length = rng.randint(4, 7)
        name = ""
        for i in range(length):
            if i % 2 == 0:
                name += rng.choice(consonants)
            else:
                name += rng.choice(vowels)
        return name
    
    else:
        # Short var dengan underscore prefix
        return "_" + rng.choice(PREFIXES) + str(rng.randint(10, 99))


def _extract_local_var_names(source: str) -> Set[str]:
    """
    Ekstrak nama variabel lokal (dalam function body).
    Hanya yang aman di-rename.
    """
    candidates = set()
    
    # Pattern: tipe variabel = ... atau tipe variabel; di dalam fungsi
    all_types = r'(?:uint\d*|int\d*|bool|address|bytes\d*|string|' + \
                '|'.join(re.escape(t) for t in FHE_ALL_TYPES) + r')'
    
    # Local var declarations
    pattern = rf'\b{all_types}\b\s+(\w+)\s*[;=,)]'
    for m in re.finditer(pattern, source):
        name = m.group(1)
        if name not in SOLIDITY_KEYWORDS and len(name) > 1:
            candidates.add(name)
    
    return candidates


def _extract_function_params(source: str) -> Set[str]:
    """Ekstrak parameter fungsi yang aman di-rename."""
    params = set()
    
    # Match function signatures
    func_pattern = r'\bfunction\s+\w+\s*\(([^)]*)\)'
    for func_match in re.finditer(func_pattern, source):
        param_str = func_match.group(1)
        # Extract param names (last word before , atau ))
        param_names = re.findall(
            r'\b(?:uint\d*|int\d*|bool|address|bytes\d*|string|' +
            '|'.join(re.escape(t) for t in FHE_ALL_TYPES) +
            r')\b\s+(?:memory\s+|calldata\s+|storage\s+)?(\w+)',
            param_str
        )
        for name in param_names:
            if name not in SOLIDITY_KEYWORDS and len(name) > 1:
                params.add(name)
    
    return params


def _find_protected_names(source: str) -> Set[str]:
    """
    Nama yang TIDAK boleh di-rename karena dipakai di konteks kritis.
    """
    protected = set()
    
    # Nama yang dipakai di TFHE.allow() - kritis untuk ACL
    allow_pattern = r'TFHE\.allow(?:This|All)?\s*\(\s*(\w+)'
    protected.update(re.findall(allow_pattern, source))
    
    # Nama yang dipakai di TFHE operations - jangan rename arguments
    tfhe_pattern = r'TFHE\.(\w+)\s*\(\s*(\w+)'
    for m in re.finditer(tfhe_pattern, source):
        arg = m.group(2)
        if arg not in SOLIDITY_KEYWORDS:
            protected.add(arg)
    
    # FHE.fromExternal atau FHE.decrypt — argument penting
    fhe_pattern = r'FHE\.(?:fromExternal|decrypt)\s*\(\s*(\w+)'
    protected.update(re.findall(fhe_pattern, source))
    
    # Nama yang dipakai di emit event
    emit_pattern = r'emit\s+\w+\s*\(([^)]*)\)'
    for m in re.finditer(emit_pattern, source):
        args = re.findall(r'\b([a-zA-Z_]\w*)\b', m.group(1))
        protected.update(args)
    
    # Return values
    return_pattern = r'\breturn\s+(\w+)'
    protected.update(re.findall(return_pattern, source))
    
    # State variable names (jangan rename state vars)
    state_pattern = r'(?:private|public|internal)\s+(?:\w+)\s+(\w+)\s*[;=]'
    protected.update(re.findall(state_pattern, source))
    
    # Function parameters yang dipakai di FHE/TFHE operations
    # Pattern: bytes calldata inputProof — jangan rename
    param_pattern = r'function\s+\w+\s*\([^)]*\b(\w+)\s*\)'
    protected.update(re.findall(param_pattern, source))
    
    return protected


def apply_variable_renaming(
    meta: ContractMetadata,
    strategy: int = 0,
    seed: Optional[int] = None
) -> str:
    """
    Apply variable renaming ke source code.
    Return source code yang sudah di-rename.
    """
    if seed is None:
        seed = hash(meta.filename) % (2**31)
    
    source = meta.raw_source
    
    # Kumpulkan kandidat rename
    local_vars = _extract_local_var_names(source)
    func_params = _extract_function_params(source)
    candidates = local_vars | func_params
    
    # Hapus yang protected
    protected = _find_protected_names(source)
    candidates -= protected
    candidates -= SOLIDITY_KEYWORDS
    
    if not candidates:
        return source
    
    # Build rename mapping
    rename_map: Dict[str, str] = {}
    used_names: Set[str] = set()
    
    rng = random.Random(seed)
    for i, var_name in enumerate(sorted(candidates)):  # sorted untuk determinism
        var_seed = seed + i * 137  # deterministik per variabel
        attempts = 0
        new_name = var_name  # fallback
        
        while attempts < 10:
            candidate_name = _generate_new_name(var_name, var_seed + attempts, strategy)
            if (candidate_name not in used_names and 
                candidate_name not in SOLIDITY_KEYWORDS and
                candidate_name != var_name and
                candidate_name not in candidates):
                new_name = candidate_name
                break
            attempts += 1
        
        rename_map[var_name] = new_name
        used_names.add(new_name)
    
    # Apply rename (whole-word replacement, case-sensitive)
    result = source
    for old_name, new_name in rename_map.items():
        result = re.sub(r'\b' + re.escape(old_name) + r'\b', new_name, result)
    
    return result



