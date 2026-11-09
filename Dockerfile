# 의존성 버전 검증에 사용한 Python 버전으로 고정
FROM python:3.12.16-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=utf-8 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    HF_HOME=/app/.cache/huggingface

WORKDIR /app

# 1) 라이브러리 설치 (레이어 캐시 활용을 위해 먼저 수행)
COPY requirements.txt .
RUN pip install -r requirements.txt

# 2) 모델을 이미지에 포함 (리비전 고정 검증 포함)
COPY scripts/ scripts/
RUN python scripts/download_model.py

# 3) 앱 코드
COPY app.py .

# 실행 시 인터넷 없이 이미지 내부 모델만 사용
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

# 4) 빌드 단계 검증: 고정 버전 / 오프라인 모델 로드 / 실제 추론 (실패 시 빌드 중단)
RUN python scripts/verify_model.py

RUN useradd --create-home --uid 1000 appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/', timeout=4).status == 200 else 1)"

# app.py 의 __main__ 은 127.0.0.1 로 바인딩하므로 컨테이너에서는 0.0.0.0 으로 실행
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
