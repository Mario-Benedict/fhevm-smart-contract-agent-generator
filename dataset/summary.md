# FHEVM Vulnerability Dataset — Summary

Generated: 2026-05-10 (revised)

## Overview

| Metric | Value |
|--------|-------|
| Total contracts | 1022 |
| Vulnerable | 772 |
| Safe (clean) | 250 |
| Vulnerability rate | 75.5% |

## Label Distribution

| Label | Contract Count |
|-------|---------------|
| acl_misconfig | 422 |
| arithmetic_overflow_underflow | 372 |
| callback_replay | 372 |

## Label Combination Breakdown

| Combination | Count |
|-------------|-------|
| Single-label (ACL only) | 150 |
| Single-label (Arithmetic only) | 150 |
| Single-label (Callback only) | 150 |
| Dual-label | 250 |
| Triple-label | 72 |
| Safe (no labels) | 250 |

## Multi-marker Coverage

All vulnerable contracts contain 2+ inline markers per vulnerability class:

| Metric | Count |
|--------|-------|
| ACL contracts with 2+ `[acl_misconfig]` markers | 422/422 |
| Arithmetic contracts with 2+ `[arithmetic_overflow_underflow]` markers | 372/372 |
| Callback contracts with 2+ `[callback_replay]` markers | 372/372 |

## Vulnerability Classes

### acl_misconfig (OWASP SC01)
Improper FHE.allow() grants exposing private aggregate state (total P&L, pool balances,
portfolio-level metrics) to unauthorized parties. Includes over-permissive allowances
leaking encrypted handles that should remain contract-private.

### arithmetic_overflow_underflow (OWASP SC09)
Unchecked FHE arithmetic operations (FHE.mul, FHE.sub, FHE.add) without pre-operation
bounds checks or FHE.select guards. No overflow/underflow checking present — values
silently wrap around on euint64 boundaries.

### callback_replay (OWASP SC06)
Async decryption settlement with state update (nonce increment, pending deletion) placed
after external call (payable.call), enabling reentrancy-based replay of encrypted
settlement amounts. Includes both single and batch settlement replay vectors.

## Safe Contract Hardening

| Metric | Count |
|--------|-------|
| Safe contracts with FHE.sub operations | 134 |
| Safe contracts with FHE.mul operations | 90 |
| Safe contracts with FHE.select guards | 144 |
| Safe contracts with vulnerability markers | 0 |

Safe contracts use OpenZeppelin-recommended fhEVM patterns:
- `FHE.select(FHE.ge(a, b), FHE.sub(a, b), FHE.asEuint64(0))` for safe subtraction
- `FHE.le(operand, FHE.asEuint64(type(uint64).max / constant))` for multiplication bounds
- Proper ACL grants scoped only to authorized parties

## Category Distribution

| Category | Count |
|----------|-------|
| Other | 407 |
| ERC20 | 102 |
| Auction | 88 |
| Voting | 79 |
| Lending | 53 |
| Gaming | 49 |
| DeFi | 42 |
| Payments | 37 |
| Insurance | 36 |
| Staking | 27 |
| SupplyChain | 27 |
| Identity | 26 |
| Healthcare | 18 |
| Governance | 18 |
| NFT | 13 |

## Files

| File | Description |
|------|-------------|
| `dataset/labels.jsonl` | Ground-truth labels with line-level vuln_locations, one JSON object per line |
| `dataset/progress.json` | Pipeline run metadata and per-contract status |
| `contracts/final/` | 1022 processed .sol files (250 safe + 772 vulnerable) |

## labels.jsonl Schema

```json
{
  "id": "0042",
  "file": "ContractName.sol",
  "labels": ["acl_misconfig", "arithmetic_overflow_underflow"],
  "is_vulnerable": true,
  "vuln_locations": {
    "acl_misconfig": "L39,L40",
    "arithmetic_overflow_underflow": "L87,L88"
  },
  "category": "DeFi",
  "complexity": "medium",
  "injected_count": 4
}
```

- `labels`: Array of vulnerability class names, or `"safe"` string for clean contracts
- `vuln_locations`: Object mapping each class to comma-separated line numbers (e.g., `"L39,L40"`)
- `complexity`: `"none"` (safe), `"low"` (single-label), `"medium"` (dual-label), `"high"` (triple-label)
- `injected_count`: Total number of inline `// [vuln_class]` markers across all classes
