# AI 감성 분석 서비스
다국어 텍스트 감성 분석을 제공하는 로컬 웹 애플리케이션입니다.

## 실행 방법
1. 필요 패키지 설치: `pip install -r requirements.txt`
2. 서버 실행: `python app.py`
3. 브라우저에서 `http://127.0.0.1:8000` 접속

## Docker
`main` 브랜치에 푸시하면 GitHub Actions가 이미지를 빌드(모델 포함, 로드 검증)하여 Docker Hub에 업로드합니다.

```bash
docker run -p 8000:8000 justinhongji/hw1-sentiment:latest
```