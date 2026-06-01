"""
validator.py
Compile check untuk hasil augmentasi menggunakan hardhat compile.
Filter kontrak yang gagal compile setelah transformasi.
Setelah compile berhasil, membaca artifact (bytecode, ABI) dari hardhat.
"""

import os
import re
import json
import subprocess
import hashlib
import shutil
from typing import Optional, Tuple, List
from dataclasses import dataclass, field


@dataclass
class ValidationResult:
    filepath: str
    is_valid: bool
    error_message: str = ""
    warnings: List[str] = None
    # Compilation artifacts — populated when is_valid=True and hardhat is used
    contract_name: str = ""
    abi: List[dict] = None
    bytecode: str = ""
    deployed_bytecode: str = ""

    def __post_init__(self):
        if self.warnings is None:
            self.warnings = []
        if self.abi is None:
            self.abi = []


# ─── Hardhat discovery ────────────────────────────────────────────────────────

def _find_hardhat_root() -> Optional[str]:
    """Cari root directory hardhat project (yang punya hardhat.config.ts/js)."""
    current = os.getcwd()
    max_depth = 10
    depth = 0

    while depth < max_depth:
        if os.path.exists(os.path.join(current, "hardhat.config.ts")) or \
           os.path.exists(os.path.join(current, "hardhat.config.js")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
        depth += 1

    return None


def _check_npx_hardhat() -> bool:
    """Check apakah npx hardhat compile tersedia."""
    import platform
    is_windows = platform.system() == 'Windows'
    try:
        result = subprocess.run(
            ["npx", "hardhat", "--version"],
            capture_output=True,
            text=True,
            timeout=15,
            shell=is_windows,  # Windows: npx adalah .cmd script, butuh shell=True
        )
        return result.returncode == 0
    except Exception:
        return False


# ─── Artifact helpers ─────────────────────────────────────────────────────────

def _read_compilation_artifacts(
    hardhat_root: str,
    artifacts_base_dir: str,
    temp_dir_name: str,
    temp_filename: str,
) -> dict:
    """
    Baca hasil kompilasi (bytecode, ABI) dari hardhat artifacts.
    Returns dict dengan keys: contract_name, abi, bytecode, deployed_bytecode.
    Returns {} jika artifacts tidak ditemukan.

    Hardhat menyimpan artifacts di:
    <artifacts_base_dir>/contracts/<temp_dir_name>/<temp_filename>/<ContractName>.json
    """
    artifact_base = os.path.join(
        hardhat_root, artifacts_base_dir, "contracts", temp_dir_name, temp_filename
    )
    if not os.path.isdir(artifact_base):
        return {}

    for fname in sorted(os.listdir(artifact_base)):
        if fname.endswith('.json') and not fname.endswith('.dbg.json'):
            try:
                with open(os.path.join(artifact_base, fname), 'r', encoding='utf-8') as f:
                    art = json.load(f)
                return {
                    'contract_name':     art.get('contractName', ''),
                    'abi':               art.get('abi', []),
                    'bytecode':          art.get('bytecode', ''),
                    'deployed_bytecode': art.get('deployedBytecode', ''),
                }
            except Exception:
                continue
    return {}


def _cleanup_artifact_dir(
    hardhat_root: str,
    artifacts_base_dir: str,
    temp_dir_name: str,
    temp_filename: str,
):
    """
    Hapus artifact directory yang dibuat untuk temp contract.
    Juga hapus parent dir jika kosong.
    """
    artifact_base = os.path.join(
        hardhat_root, artifacts_base_dir, "contracts", temp_dir_name, temp_filename
    )
    if os.path.isdir(artifact_base):
        try:
            shutil.rmtree(artifact_base)
        except Exception:
            pass
    # Hapus parent (_aug_temp) jika kosong
    parent = os.path.join(hardhat_root, artifacts_base_dir, "contracts", temp_dir_name)
    try:
        if os.path.isdir(parent) and not os.listdir(parent):
            os.rmdir(parent)
    except Exception:
        pass


# ─── Hardhat compile ──────────────────────────────────────────────────────────

def validate_with_hardhat(source: str, filepath: str, hardhat_root: str) -> ValidationResult:
    """
    Validate menggunakan npx hardhat compile (hardhat.config.ts original, viaIR=true).
    BATCH=_aug_temp di-set agar hardhat hanya compile contracts/_aug_temp/ saja,
    bukan semua kontrak di contracts/ (lebih dari 2000 file).

    Temp files SELALU dihapus setelah compile.
    """
    original_cwd = os.getcwd()
    TEMP_DIR_NAME = "_aug_temp"
    temp_dir = os.path.join(hardhat_root, "contracts", TEMP_DIR_NAME)
    temp_contract_path = None
    temp_filename = None

    try:
        os.makedirs(temp_dir, exist_ok=True)

        contract_filename = os.path.basename(filepath)
        if not contract_filename.endswith(".sol"):
            contract_filename = "temp_validate.sol"

        unique_id = hashlib.md5(source.encode()).hexdigest()[:8]
        temp_filename = f"_aug_{unique_id}_{contract_filename}"
        temp_contract_path = os.path.join(temp_dir, temp_filename)

        with open(temp_contract_path, "w", encoding="utf-8") as f:
            f.write(source)

        os.chdir(hardhat_root)

        import platform
        # BATCH=_aug_temp → hardhat.config.ts pakai sources = ./contracts/_aug_temp/
        # sehingga hanya 1 file temp yang di-compile, bukan semua contracts/
        compile_env = os.environ.copy()
        compile_env["BATCH"] = TEMP_DIR_NAME

        result = subprocess.run(
            ["npx", "hardhat", "compile"],
            capture_output=True,
            text=True,
            timeout=90,
            cwd=hardhat_root,
            env=compile_env,
            shell=(platform.system() == "Windows"),
        )

        if result.returncode == 0:
            # Artifacts disimpan di artifacts/contracts/_aug_temp/<temp_filename>/
            artifacts = _read_compilation_artifacts(
                hardhat_root, "artifacts", TEMP_DIR_NAME, temp_filename
            )
            return ValidationResult(
                filepath=filepath,
                is_valid=True,
                contract_name=artifacts.get("contract_name", ""),
                abi=artifacts.get("abi", []),
                bytecode=artifacts.get("bytecode", ""),
                deployed_bytecode=artifacts.get("deployed_bytecode", ""),
            )
        else:
            error_output = result.stderr + result.stdout
            errors = []
            for line in error_output.split("\n"):
                if temp_filename in line or "Error" in line or "error" in line:
                    clean_line = line.replace(temp_filename, os.path.basename(filepath))
                    errors.append(clean_line.strip())
            error_msg = "\n".join(errors[:5]) if errors else error_output[:300]
            return ValidationResult(
                filepath=filepath,
                is_valid=False,
                error_message=error_msg,
            )

    except subprocess.TimeoutExpired:
        return ValidationResult(
            filepath=filepath,
            is_valid=False,
            error_message="Hardhat compilation timeout (>90 seconds)",
        )

    except Exception as e:
        return ValidationResult(
            filepath=filepath,
            is_valid=False,
            error_message=f"Hardhat compilation error: {str(e)[:200]}",
        )

    finally:
        # Hapus temp source file
        if temp_contract_path and os.path.exists(temp_contract_path):
            try:
                os.remove(temp_contract_path)
            except Exception:
                pass
        # Hapus artifact directory di artifacts/contracts/_aug_temp/<temp_filename>/
        if temp_filename:
            _cleanup_artifact_dir(
                hardhat_root, "artifacts", TEMP_DIR_NAME, temp_filename
            )
        # Hapus temp source dir jika kosong
        try:
            if os.path.exists(temp_dir) and not os.listdir(temp_dir):
                os.rmdir(temp_dir)
        except Exception:
            pass
        os.chdir(original_cwd)




# ─── Syntax-only validator (fallback) ─────────────────────────────────────────

def validate_syntax_only(source: str, filepath: str) -> ValidationResult:
    """
    Validasi syntax ringan tanpa solc — sebagai fallback.
    Cek hal-hal dasar yang sering rusak setelah transformasi.
    """
    errors = []

    # 1. Brace balance (skip strings dan comments)
    brace_balance = 0
    paren_balance = 0
    in_string = False
    string_char = None
    in_comment = False

    i = 0
    while i < len(source):
        if source[i] in ('"', "'") and (i == 0 or source[i-1] != '\\'):
            if not in_comment:
                if not in_string:
                    in_string = True
                    string_char = source[i]
                elif source[i] == string_char:
                    in_string = False

        if not in_string:
            if i < len(source) - 1 and source[i:i+2] == '//':
                while i < len(source) and source[i] != '\n':
                    i += 1
                continue
            elif i < len(source) - 1 and source[i:i+2] == '/*':
                in_comment = True
                i += 1
            elif i < len(source) - 1 and source[i:i+2] == '*/':
                in_comment = False
                i += 1

        if not in_string and not in_comment:
            if source[i] == '{':
                brace_balance += 1
            elif source[i] == '}':
                brace_balance -= 1
            elif source[i] == '(':
                paren_balance += 1
            elif source[i] == ')':
                paren_balance -= 1

        i += 1

    if brace_balance != 0:
        errors.append(f"Brace mismatch: unbalanced by {brace_balance}")

    if paren_balance != 0:
        errors.append(f"Paren mismatch: unbalanced by {paren_balance}")

    # 2. Pragma harus ada
    if not re.search(r'pragma\s+solidity', source):
        errors.append("Missing pragma solidity")

    # 3. Contract declaration harus ada
    if not re.search(r'\bcontract\s+\w+', source):
        errors.append("Missing contract declaration")

    # 4. Cek unknown euint sizes
    unknown_euint = re.findall(r'\beuint(\d+)\b', source)
    valid_euint_sizes = {"8", "16", "32", "64", "128", "256"}
    for size in unknown_euint:
        if size not in valid_euint_sizes:
            errors.append(f"Invalid FHE type: euint{size}")

    # 5. Cek TFHE operations
    tfhe_calls = re.findall(r'TFHE\.(\w+)\s*\(', source)
    valid_tfhe = {
        "add", "sub", "mul", "div", "rem", "min", "max",
        "eq", "ne", "lt", "le", "gt", "ge",
        "and", "or", "xor", "not", "cast",
        "asEuint8", "asEuint16", "asEuint32", "asEuint64", "asEuint128", "asEuint256",
        "randEuint8", "randEuint16", "randEuint32", "randEuint64", "randEuint128", "randEuint256",
        "select", "allow", "allowThis", "allowAll",
        "fromExternal", "decrypt", "shr", "shl", "rotl", "rotr",
    }
    for op in tfhe_calls:
        if op not in valid_tfhe:
            errors.append(f"Unknown TFHE operation: TFHE.{op}")

    # 6. Cek import statements tidak kosong
    imports = re.findall(r'import\s+([^;]+);', source)
    for imp in imports:
        if not imp.strip():
            errors.append("Empty import statement")

    if errors:
        return ValidationResult(
            filepath=filepath,
            is_valid=False,
            error_message="; ".join(errors),
        )

    return ValidationResult(filepath=filepath, is_valid=True)


# ─── Main validator ───────────────────────────────────────────────────────────

_hardhat_root: Optional[str] = None
_hardhat_available: bool = None


def _init_hardhat():
    global _hardhat_root, _hardhat_available
    if _hardhat_available is None:
        _hardhat_root = _find_hardhat_root()
        _hardhat_available = _hardhat_root is not None and _check_npx_hardhat()
        if _hardhat_available:
            print(f"[INFO] Hardhat ditemukan di: {_hardhat_root}")
        else:
            print("[WARN] Hardhat tidak ditemukan. Menggunakan syntax-only validation.")


def validate_contract(source: str, filepath: str = "contract.sol") -> ValidationResult:
    """
    Validate satu kontrak menggunakan hardhat compile.
    Jika berhasil, result.bytecode dan result.abi akan terisi.
    """
    global _hardhat_root, _hardhat_available
    _init_hardhat()

    # Syntax check dulu (cepat, sebagai early filter)
    syntax_result = validate_syntax_only(source, filepath)
    if not syntax_result.is_valid:
        return syntax_result

    # Full compile check dengan hardhat kalau tersedia
    if _hardhat_available and _hardhat_root:
        return validate_with_hardhat(source, filepath, _hardhat_root)

    # Fallback: syntax only
    return syntax_result


def validate_batch(
    contracts: List[Tuple[str, str]],  # list of (filepath, source)
    show_progress: bool = True,
) -> Tuple[List[ValidationResult], List[ValidationResult]]:
    """
    Validate batch kontrak.
    Return: (valid_results, invalid_results)
    """
    valid = []
    invalid = []

    total = len(contracts)
    for i, (filepath, source) in enumerate(contracts):
        if show_progress and i % 100 == 0:
            print(f"[VALIDATE] {i}/{total} ({len(valid)} valid, {len(invalid)} invalid)")

        result = validate_contract(source, filepath)
        if result.is_valid:
            valid.append(result)
        else:
            invalid.append(result)

    return valid, invalid
