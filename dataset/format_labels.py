import json
import csv

# Urutan label fixed
all_labels = ["acl_misconfig", "arithmetic_overflow_underflow", "callback_replay"]

# Baca semua data
records = []
with open("labels.jsonl", "r", encoding="utf-8-sig") as f:
    for line in f:
        line = line.strip()
        if line and line.startswith("{"):
            records.append(json.loads(line))

# Bangun output records
output = []
for r in records:
    active = r["labels"] if isinstance(r["labels"], list) else []
    row = {
        "id": r["id"],
        "file": r["file"],
        "labels": [1 if label in active else 0 for label in all_labels]
    }
    output.append(row)

# Simpan JSON
with open("final_labels.json", "w") as f:
    json.dump(output, f, indent=2)

# Simpan JSONL
with open("final_labels.jsonl", "w") as f:
    for row in output:
        f.write(json.dumps(row) + "\n")

# Simpan CSV
with open("final_labels.csv", "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["id", "file", "labels"])
    writer.writeheader()
    for row in output:
        writer.writerow({"id": row["id"], "file": row["file"], "labels": row["labels"]})

print(f"Selesai! {len(output)} records")
print(f"Urutan label: {all_labels}")