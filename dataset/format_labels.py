import json
import csv

# Baca semua data
records = []
with open("labels.jsonl", "r") as f:  # <-- ganti ini
    for line in f:
        line = line.strip()
        if line and line.startswith("{"):
            records.append(json.loads(line))

# Kumpulkan semua label unik, urutkan
all_labels = sorted(set(
    label
    for r in records
    for label in (r["labels"] if isinstance(r["labels"], list) else [])
))

# Bangun output records
output = []
for r in records:
    row = {"id": r["id"], "file": r["file"]}
    active = r["labels"] if isinstance(r["labels"], list) else []
    for label in all_labels:
        row[label] = 1 if label in active else 0
    output.append(row)

# Simpan JSON
with open("final_labels.json", "w") as f:
    json.dump(output, f, indent=2)

# Simpan JSONL
with open("final_labels.jsonl", "w") as f:  # <-- tambah ini
    for row in output:
        f.write(json.dumps(row) + "\n")

# Simpan CSV
fieldnames = ["id", "file"] + all_labels
with open("final_labels.csv", "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(output)

print(f"Selesai! {len(output)} records, {len(all_labels)} label kolom: {all_labels}")