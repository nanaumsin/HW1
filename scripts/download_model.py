"""이미지 빌드 시 감성 분석 모델을 미리 받아 이미지에 포함시킨다.

- 컨테이너 실행 시 인터넷 다운로드 없이 즉시 모델 로드 (HF_HUB_OFFLINE=1)
- 모델 리비전(커밋 해시)을 고정하여, 원격 모델이 바뀌면 빌드를 실패시켜 재현성 보장
- PyTorch 추론에 필요한 파일(safetensors)만 받아 이미지 크기 절감
"""
import os
import sys

from huggingface_hub import snapshot_download

MODEL_ID = os.environ.get("MODEL_ID", "nlptown/bert-base-multilingual-uncased-sentiment")
MODEL_REVISION = os.environ.get("MODEL_REVISION", "8f6f4e3a8f70be4b65d3a4a8762b6d781cda240d")

# app.py 는 revision 없이 모델을 로드하므로 'main' 기준으로 캐시를 만들고,
# 받은 커밋이 고정한 리비전과 같은지 확인한다.
path = snapshot_download(
    repo_id=MODEL_ID,
    revision="main",
    allow_patterns=[
        "config.json",
        "model.safetensors",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "vocab.txt",
    ],
)
commit = os.path.basename(path.rstrip("/\\"))
print(f"Downloaded {MODEL_ID}@{commit} -> {path}")

if commit != MODEL_REVISION:
    print(
        f"[FAIL] remote model revision changed: expected {MODEL_REVISION}, got {commit}. "
        "Verify the new revision and update MODEL_REVISION."
    )
    sys.exit(1)
print("[OK] model revision matches pinned revision")
