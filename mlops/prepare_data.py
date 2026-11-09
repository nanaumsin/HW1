"""Prepare a 100-sample public evaluation set (30 tuning / 70 final evaluation).

Source  : NSMC (Naver Sentiment Movie Corpus) test split
          Hugging Face dataset card: https://huggingface.co/datasets/e9t/nsmc  (license: CC-BY-2.0)
          Raw data referenced by that card: https://github.com/e9t/nsmc
Labels  : 0 = negative, 1 = positive
Sampling: fixed seed, balanced 50 positive / 50 negative, stratified 15/15 tuning + 35/35 eval.

The generated files (mlops/data/) are NOT committed; rerun this script to reproduce them.
"""
from __future__ import annotations

import hashlib
import json
import random
import urllib.request
from pathlib import Path

SOURCE_URL = "https://raw.githubusercontent.com/e9t/nsmc/master/ratings_test.txt"
EXPECTED_SHA256 = None  # filled on first run and recorded in manifest.json
SEED = 20261109
N_PER_CLASS = 50
TUNE_PER_CLASS = 15

OUT = Path(__file__).resolve().parent / "data"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    raw_path = OUT / "ratings_test.txt"
    if not raw_path.exists():
        urllib.request.urlretrieve(SOURCE_URL, raw_path)
    raw = raw_path.read_bytes()
    sha = hashlib.sha256(raw).hexdigest()
    if EXPECTED_SHA256 and sha != EXPECTED_SHA256:
        raise SystemExit(f"source file changed: {sha}")

    rows = []
    for line in raw.decode("utf-8").splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        doc_id, text, label = parts
        text = text.strip()
        if len(text) < 5:  # drop empty / trivially short reviews
            continue
        rows.append({"id": doc_id, "text": text, "label": int(label)})

    rng = random.Random(SEED)
    tune, evaluation = [], []
    for label in (0, 1):
        pool = [r for r in rows if r["label"] == label]
        picked = rng.sample(pool, N_PER_CLASS)
        tune += picked[:TUNE_PER_CLASS]
        evaluation += picked[TUNE_PER_CLASS:]
    rng.shuffle(tune)
    rng.shuffle(evaluation)

    assert not ({r["id"] for r in tune} & {r["id"] for r in evaluation})
    for name, data in (("tune", tune), ("eval", evaluation)):
        with open(OUT / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for r in data:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    manifest = {
        "dataset": "e9t/nsmc (test split)",
        "dataset_card": "https://huggingface.co/datasets/e9t/nsmc",
        "license": "CC-BY-2.0",
        "source_url": SOURCE_URL,
        "source_sha256": sha,
        "seed": SEED,
        "tune": {"n": len(tune), "positive": sum(r["label"] for r in tune)},
        "eval": {"n": len(evaluation), "positive": sum(r["label"] for r in evaluation)},
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
