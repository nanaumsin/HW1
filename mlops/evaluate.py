"""Offline evaluation of sentiment strategies on the NSMC sample.

usage:
  python mlops/evaluate.py --split tune --strategies baseline,attempt1,attempt2 [--tune-thresholds]
  python mlops/evaluate.py --split eval --strategies baseline,attempt2

Metric (same for every strategy): binary accuracy on positive/negative reviews.
A "neutral" prediction counts as an error (the review is labelled pos or neg).
Also reported: macro-F1 over {neg,pos}, neutral rate, latency.
Results go to mlops/results/ (not committed).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from sentiment import NEGATIVE, POSITIVE, SentimentService  # noqa: E402

DATA = ROOT / "mlops" / "data"
RESULTS = ROOT / "mlops" / "results"


def load(split: str) -> list[dict]:
    return [json.loads(l) for l in (DATA / f"{split}.jsonl").read_text(encoding="utf-8").splitlines() if l]


def to_label(sentiment: str) -> int | None:
    return 1 if sentiment == POSITIVE else 0 if sentiment == NEGATIVE else None


def metrics(rows: list[dict], preds: list[dict]) -> dict:
    y = [r["label"] for r in rows]
    p = [to_label(x["sentiment"]) for x in preds]
    acc = sum(a == b for a, b in zip(y, p)) / len(y)
    f1s = []
    for c in (0, 1):
        tp = sum(a == c and b == c for a, b in zip(y, p))
        fp = sum(a != c and b == c for a, b in zip(y, p))
        fn = sum(a == c and b != c for a, b in zip(y, p))
        prec = tp / (tp + fp) if tp + fp else 0.0
        rec = tp / (tp + fn) if tp + fn else 0.0
        f1s.append(2 * prec * rec / (prec + rec) if prec + rec else 0.0)
    return {
        "n": len(y),
        "accuracy": round(acc, 4),
        "macro_f1": round(sum(f1s) / 2, 4),
        "neutral_rate": round(sum(x is None for x in p) / len(p), 4),
        "errors": sum(a != b for a, b in zip(y, p)),
    }


def run(service: SentimentService, rows: list[dict]) -> tuple[list[dict], float]:
    t0 = time.perf_counter()
    preds = [service.analyze(r["text"]) for r in rows]
    return preds, (time.perf_counter() - t0) / len(rows) * 1000


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", choices=["tune", "eval"], required=True)
    ap.add_argument("--strategies", default="baseline,attempt1,attempt2")
    ap.add_argument("--tune-thresholds", action="store_true",
                    help="grid-search expected-star thresholds (allowed on the tune split only)")
    args = ap.parse_args()
    if args.tune_thresholds and args.split != "tune":
        raise SystemExit("threshold tuning on the evaluation split is not allowed")

    rows = load(args.split)
    RESULTS.mkdir(parents=True, exist_ok=True)
    report = {"split": args.split, "strategies": {}}

    for strategy in args.strategies.split(","):
        svc = SentimentService(strategy=strategy)
        if args.tune_thresholds and strategy in {"attempt1", "attempt2"}:
            # expected star score is threshold-independent: compute once, then grid search
            from sentiment import normalize
            exp = [svc._expected_star(normalize(r["text"]))["expected_stars"] for r in rows]
            best = None
            for pos in [x / 10 for x in range(25, 41)]:
                for neg in [x / 10 for x in range(20, 36)]:
                    if neg > pos:
                        continue
                    pred = [1 if e >= pos else 0 if e <= neg else None for e in exp]
                    acc = sum(a == r["label"] for a, r in zip(pred, rows)) / len(rows)
                    # prefer higher accuracy, then a narrower neutral band (fewer abstentions)
                    key = (acc, -(pos - neg))
                    if best is None or key > best[0]:
                        best = (key, pos, neg)
            svc.pos_threshold, svc.neg_threshold = best[1], best[2]
        preds, ms = run(svc, rows)
        m = metrics(rows, preds)
        m["avg_latency_ms"] = round(ms, 1)
        m["thresholds"] = {"pos": svc.pos_threshold, "neg": svc.neg_threshold} if strategy != "baseline" else None
        m["model"] = svc.model_name
        report["strategies"][strategy] = m
        with open(RESULTS / f"{args.split}_{strategy}_predictions.jsonl", "w", encoding="utf-8") as f:
            for r, p in zip(rows, preds):
                rec = {"id": r["id"], "text": r["text"], "gold": r["label"],
                       "pred_label": p["label"], "sentiment": p["sentiment"], "confidence": p["confidence"],
                       "route": p.get("route"), "correct": to_label(p["sentiment"]) == r["label"]}
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(f"[{args.split}] {strategy:9s} {json.dumps(m, ensure_ascii=False)}", flush=True)

    (RESULTS / f"{args.split}_report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False),
                                                       encoding="utf-8")


if __name__ == "__main__":
    main()
