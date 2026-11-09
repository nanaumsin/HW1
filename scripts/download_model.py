"""이미지 빌드 시 감성 분석 모델을 미리 받아 이미지에 포함시킨다.

- 컨테이너 실행 시 인터넷 다운로드 없이 즉시 모델 로드 (HF_HUB_OFFLINE=1)
- 모델 리비전(커밋 해시)을 고정하여, 원격 모델이 바뀌면 빌드를 실패시켜 재현성 보장
- PyTorch 추론에 필요한 파일(safetensors + 설정/토크나이저)만 받아 이미지 크기 절감
"""
import os
import sys

from huggingface_hub import snapshot_download

# (model id, pinned revision)
MODELS = [
    ("nlptown/bert-base-multilingual-uncased-sentiment", "8f6f4e3a8f70be4b65d3a4a8762b6d781cda240d"),  # MIT
    ("Copycats/koelectra-base-v3-generalized-sentiment-analysis", "370f325ce11aabd837b89bfb3ffdc26fde354689"),  # Apache-2.0
]

failed = False
for model_id, revision in MODELS:
    # app 은 revision 없이 로드하므로 'main' 기준으로 캐시를 만들고, 받은 커밋이 고정값과 같은지 확인
    path = snapshot_download(
        repo_id=model_id,
        revision="main",
        allow_patterns=["*.json", "*.txt", "model.safetensors"],
    )
    commit = os.path.basename(path.rstrip("/\\"))
    print(f"Downloaded {model_id}@{commit}")
    if commit != revision:
        print(f"[FAIL] {model_id}: expected revision {revision}, got {commit}")
        failed = True
    else:
        print(f"[OK] {model_id} revision matches pinned revision")

sys.exit(1 if failed else 0)
