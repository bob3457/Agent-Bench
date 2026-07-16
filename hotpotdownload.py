import json
from datasets import load_dataset

ds = load_dataset("hotpotqa/hotpot_qa", "fullwiki", split="validation")
items = [{
    "_id": r["id"],
    "question": r["question"],
    "answer": r["answer"],
    "type": r["type"],
    "level": r["level"],
    "supporting_facts": [[t, i] for t, i in
                         zip(r["supporting_facts"]["title"],
                             r["supporting_facts"]["sent_id"])],
    "context": [[t, s] for t, s in
                zip(r["context"]["title"], r["context"]["sentences"])],
} for r in ds]

with open("datasets/hotpot_dev_fullwiki_v1.json", "w") as f:
    json.dump(items, f)
print(len(items))  # expect 7405