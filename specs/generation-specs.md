# FHEVM Training Dataset Generation Spec

## Target
Generate 100 unique fhEVM smart contracts per batch.
Total target: 1000 contracts across 10 batches.

## Distribution per batch (100 contracts):
- 20x Confidential ERC20 variants
- 15x Encrypted Voting variants  
- 15x Blind Auction variants
- 15x Confidential DeFi (lending/staking)
- 15x Private Gaming / RNG
- 10x Encrypted Access Control
- 10x Mixed / creative

## Variation axes (WAJIB berbeda tiap contract):
1. Nama contract & token symbol dan boleh implementasi logika atau memanfaatkan library lainnya seperti openzeppelin atau uniswap
2. Encrypted type precision (euint8 vs euint16 vs euint32 vs euint64)
3. Logic complexity (simple / medium / complex)
4. ACL pattern (allowThis only / allow specific addr / allowTransient)
5. Tambah 1-2 fitur unik (pause, blacklist, vesting, timelock, dll)

## Output format
- Satu file per contract: contracts/generated/{NamaContract}.sol
- Semua harus compilable dengan hardhat compile