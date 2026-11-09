"""Sentiment inference shared by the web app (app.py) and the offline evaluation (mlops/).

Strategies
----------
baseline : original app.py behaviour
           nlptown 5-star model, argmax star -> >=4 positive, 3 neutral, <=2 negative
attempt1 : preprocessing + decision improvement on the same model
           text normalisation (repeated characters / whitespace) and the expected star
           score over all 5 classes with thresholds tuned on the tuning split
attempt2 : attempt1 + model swap for Korean input
           Hangul text -> Korean pretrained sentiment model (KoELECTRA, binary),
           other languages keep the multilingual nlptown model (feature preserved)
"""
from __future__ import annotations

import os
import re

from transformers import pipeline

MULTI_MODEL_ID = "nlptown/bert-base-multilingual-uncased-sentiment"
KO_MODEL_ID = "Copycats/koelectra-base-v3-generalized-sentiment-analysis"

POSITIVE = "긍정적 😊"
NEUTRAL = "중립적 😐"
NEGATIVE = "부정적 😞"

_HANGUL = re.compile(r"[가-힣ㄱ-ㆎ]")
_REPEAT = re.compile(r"(.)\1{2,}")
_SPACES = re.compile(r"\s+")


def normalize(text: str) -> str:
    """Collapse 3+ repeated characters (e.g. 'ㅋㅋㅋㅋ', '!!!!') to 2 and squeeze whitespace."""
    return _SPACES.sub(" ", _REPEAT.sub(r"\1\1", text)).strip()


def is_korean(text: str) -> bool:
    return bool(_HANGUL.search(text))


class SentimentService:
    def __init__(
        self,
        strategy: str | None = None,
        pos_threshold: float | None = None,
        neg_threshold: float | None = None,
    ) -> None:
        self.strategy = strategy or os.environ.get("SENTIMENT_STRATEGY", "attempt2")
        if self.strategy not in {"baseline", "attempt1", "attempt2"}:
            raise ValueError(f"unknown strategy: {self.strategy}")
        # thresholds on the expected star score (1..5); tuned on the tuning split only
        # defaults = values selected by grid search on the tuning split (mlops/REPORT.md)
        self.pos_threshold = pos_threshold if pos_threshold is not None else float(os.environ.get("POS_THRESHOLD", "3.0"))
        self.neg_threshold = neg_threshold if neg_threshold is not None else float(os.environ.get("NEG_THRESHOLD", "3.0"))

        self.multi = pipeline("text-classification", model=MULTI_MODEL_ID, top_k=None)
        self.ko = pipeline("text-classification", model=KO_MODEL_ID) if self.strategy == "attempt2" else None

    @property
    def model_name(self) -> str:
        if self.strategy == "attempt2":
            return f"{KO_MODEL_ID} (ko) + {MULTI_MODEL_ID}"
        return MULTI_MODEL_ID

    def analyze(self, text: str) -> dict:
        if self.strategy == "baseline":
            return self._baseline(text)
        clean = normalize(text)
        if self.strategy == "attempt2" and is_korean(clean):
            return self._korean(clean)
        return self._expected_star(clean)

    # --- strategies -------------------------------------------------------------------
    def _scores(self, text: str) -> list[dict]:
        out = self.multi(text)
        return out[0] if out and isinstance(out[0], list) else out

    def _baseline(self, text: str) -> dict:
        top = max(self._scores(text), key=lambda s: s["score"])
        stars = int(top["label"].split()[0])
        sentiment = POSITIVE if stars >= 4 else NEUTRAL if stars == 3 else NEGATIVE
        return {"label": top["label"], "sentiment": sentiment, "confidence": round(float(top["score"]), 4),
                "route": "multilingual"}

    def _expected_star(self, text: str) -> dict:
        scores = self._scores(text)
        expected = sum(int(s["label"].split()[0]) * s["score"] for s in scores)
        top = max(scores, key=lambda s: s["score"])
        if expected >= self.pos_threshold:
            sentiment = POSITIVE
        elif expected <= self.neg_threshold:
            sentiment = NEGATIVE
        else:
            sentiment = NEUTRAL
        return {"label": f"{expected:.2f} stars (expected)", "sentiment": sentiment,
                "confidence": round(float(top["score"]), 4), "route": "multilingual",
                "expected_stars": round(expected, 4)}

    def _korean(self, text: str) -> dict:
        res = self.ko(text)[0]
        positive = str(res["label"]) in {"1", "LABEL_1", "positive"}
        return {"label": "positive" if positive else "negative",
                "sentiment": POSITIVE if positive else NEGATIVE,
                "confidence": round(float(res["score"]), 4), "route": "korean"}
