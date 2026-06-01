# FHEVM Smart Contract Augmentation Pipeline

Pipeline augmentasi data untuk smart contract berbasis **fhevm (Zama)**. Menghasilkan ribuan kontrak baru dari kontrak input menggunakan 4 tipe transformasi deterministik — tanpa LLM, tanpa vulnerability injection.

---

## Cara Pakai

```bash
# Dari root project
python augmentation/augment_transform.py run      # jalankan / lanjutkan pipeline
python augmentation/augment_transform.py status   # cek progress + distribusi kelas
python augmentation/augment_transform.py reset    # reset semua progress (konfirmasi diperlukan)
```

---

## Cara Kerja Pipeline

Untuk tiap kontrak di `contracts_input/`, pipeline melakukan loop:

```
augment → compile → augment → compile → ...
```

Setiap augmentasi langsung divalidasi lewat `npx hardhat compile`. Jika compile gagal, kontrak itu dilewati dan dicatat di log. Setiap **100 kontrak berhasil**, pipeline berhenti dan minta konfirmasi sebelum lanjut.

### 4 Tipe Transformasi

| Tipe | Deskripsi |
|------|-----------|
| `rename` | Rename local variables dan function parameters |
| `expression` | Substitusi ekspresi TFHE/Solidity yang semantically equivalent |
| `fhe_swap` | Ganti FHE type (upcast: `euint32` → `euint64`, dll) |
| `dead_code` | Inject dead code (komentar, `require(true)`, unreachable branch) |

### Balancing Otomatis

Pipeline membaca distribusi kelas dari `dataset/final_labels.jsonl` dan menyesuaikan jumlah variant per kontrak agar dataset hasil augmentasi seimbang. Kelas minoritas mendapat lebih banyak variant. Label augmented kontrak **diwarisi** dari kontrak aslinya.

---

## Output

```
augmentation/
├── contracts_input/          ← taruh .sol files di sini
├── contracts_output/
│   ├── rename/               ← hasil augmentasi per tipe
│   ├── expression/
│   ├── fhe_swap/
│   └── dead_code/
├── metadata/
│   └── <tipe>/<nama>.json    ← bytecode, ABI, contract name per kontrak
├── labels/
│   └── augmented_labels.jsonl  ← label output (format sama dengan final_labels.jsonl)
├── progress/
│   └── pipeline_progress.json  ← state pipeline (untuk resume)
└── logs/
    ├── pipeline.log
    └── failed_transforms.jsonl
```

> Semua output tersimpan di dalam folder `augmentation/`. Tidak ada file yang ditulis di luar folder ini.
