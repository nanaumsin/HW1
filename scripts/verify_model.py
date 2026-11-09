"""이미지 빌드 시 실행되는 검증 스크립트 (실패 시 exit 1 -> docker build 중단).

1) requirements.txt 에 고정한 버전이 실제로 설치되었는지 확인
2) 오프라인 상태(HF_HUB_OFFLINE=1)에서 app.py 를 import 하여
   이미지에 포함된 모델이 정상 로드되는지 확인
3) 추론 1회가 오류 없이 실행되는지 확인 (정확도/성능 검사는 하지 않음)
4) 메인 페이지(HTML) 응답 확인
"""
from __future__ import annotations

import asyncio
import os
import sys
from importlib.metadata import version
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

SAMPLE_TEXT = "이번 프로젝트 정말 기대 이상이네요!"


def check_pinned_versions() -> None:
    for line in (ROOT / "requirements.txt").read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        name, expected = line.split("==")
        installed = version(name)
        assert installed == expected, f"{name}: expected {expected}, got {installed}"
        print(f"  [OK] {name}=={installed}")


def check_model_and_inference() -> None:
    assert os.environ.get("HF_HUB_OFFLINE") == "1", "verification must run offline (HF_HUB_OFFLINE=1)"

    import app  # 모듈 import 시 pipeline 으로 모델 로드

    assert app.nlp_model is not None, "app.nlp_model is None (model failed to load)"
    print(f"  [OK] model loaded offline: {app.nlp_model.model_name}")

    # 추론이 오류 없이 실행되는지만 확인 (분류 정확도/성능은 검사하지 않음)
    # 한국어 -> 한국어 모델 경로, 영어 -> 다국어 모델 경로 각각 1회
    for text in (SAMPLE_TEXT, "This product is amazing."):
        res = asyncio.run(app.predict(app.TextRequest(text=text)))
        required = {"text", "label", "sentiment", "confidence", "model", "version"}
        assert required <= set(res), res
        print(f"  [OK] inference runs: {res['label']} ({res['confidence']:.2f})")

    html = asyncio.run(app.read_index())
    assert html.status_code == 200 and b"<html" in html.body
    print("  [OK] index page renders")


def main() -> int:
    for title, fn in [
        ("Pinned library versions", check_pinned_versions),
        ("Model load & inference", check_model_and_inference),
    ]:
        print(f"== {title}")
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            print(f"  [FAIL] {type(exc).__name__}: {exc}")
            return 1
    print("All verification checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
