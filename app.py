from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from transformers import pipeline
import uvicorn

app = FastAPI(title="Text Sentiment Analysis API")

# 사전 학습된 다국어 감성 분석 모델 로드 (최초 실행 시 자동 다운로드됨)
try:
    nlp_model = pipeline("sentiment-analysis", model="nlptown/bert-base-multilingual-uncased-sentiment")
except Exception as e:
    nlp_model = None
    print(f"모델 로드 실패: {e}")

class TextRequest(BaseModel):
    text: str

# 프론트엔드 HTML/CSS/JS 코드를 문자열로 포함
HTML_CONTENT = """
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AI 감성 분석 서비스</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f8f9fa; margin: 0; padding: 50px; display: flex; justify-content: center; }
        .container { background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); width: 100%; max-width: 500px; }
        h2 { color: #212529; text-align: center; margin-bottom: 5px; }
        p.subtitle { text-align: center; color: #6c757d; font-size: 14px; margin-bottom: 20px; }
        textarea { width: 100%; height: 120px; padding: 12px; border: 1px solid #ced4da; border-radius: 8px; box-sizing: border-box; resize: none; font-size: 14px; margin-bottom: 15px; }
        textarea:focus { outline: none; border-color: #80bdff; }
        button { width: 100%; padding: 12px; background: #0d6efd; color: white; border: none; border-radius: 8px; cursor: pointer; font-size: 16px; font-weight: bold; transition: background 0.2s; }
        button:hover { background: #0b5ed7; }
        button:disabled { background: #6c757d; cursor: not-allowed; }
        .result { margin-top: 25px; padding: 20px; background: #f8f9fa; border-radius: 8px; border: 1px solid #e9ecef; display: none; }
        .result p { margin: 8px 0; color: #495057; font-size: 15px; }
    </style>
</head>
<body>
    <div class="container">
        <h2>텍스트 감성 분석기 🧠</h2>
        <p class="subtitle">한국어, 영어 등 다국어 리뷰/문장 분석</p>
        <textarea id="textInput" placeholder="분석할 텍스트를 입력하세요...&#10;(예: 이번 프로젝트 정말 기대 이상이네요!)"></textarea>
        <button id="analyzeBtn" onclick="analyzeText()">분석하기</button>
        
        <div class="result" id="resultBox">
            <p><strong>종합 분석:</strong> <span id="sentiment"></span></p>
            <p><strong>세부 등급:</strong> <span id="label"></span></p>
            <p><strong>AI 신뢰도:</strong> <span id="confidence"></span></p>
        </div>
    </div>

    <script>
        async function analyzeText() {
            const text = document.getElementById('textInput').value;
            if (!text.trim()) {
                alert('텍스트를 입력해주세요.');
                return;
            }

            const btn = document.getElementById('analyzeBtn');
            btn.innerText = 'AI가 분석 중입니다...';
            btn.disabled = true;

            try {
                const response = await fetch('/predict', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ text: text })
                });
                
                const data = await response.json();
                
                if (response.ok) {
                    document.getElementById('sentiment').innerText = data.sentiment;
                    document.getElementById('label').innerText = data.label;
                    document.getElementById('confidence').innerText = (data.confidence * 100).toFixed(1) + '%';
                    document.getElementById('resultBox').style.display = 'block';
                } else {
                    alert('오류 발생: ' + data.detail);
                }
            } catch (error) {
                alert('서버와 통신할 수 없습니다. 포트가 열려있는지 확인하세요.');
            } finally {
                btn.innerText = '분석하기';
                btn.disabled = false;
            }
        }
    </script>
</body>
</html>
"""

@app.get("/")
async def read_index():
    # 저장된 HTML 문자열을 그대로 브라우저에 반환
    return HTMLResponse(content=HTML_CONTENT)

@app.post("/predict")
async def predict(request: TextRequest):
    if not nlp_model:
        raise HTTPException(status_code=500, detail="모델이 로드되지 않았습니다.")
    if not request.text.strip():
        raise HTTPException(status_code=400, detail="텍스트가 비어있습니다.")
    
    # 모델 추론
    results = nlp_model(request.text)
    
    # 결과 후처리
    score_str = results[0]['label'].split()[0]
    score = int(score_str)
    
    if score >= 4:
        sentiment = "긍정적 😊"
    elif score == 3:
        sentiment = "중립적 😐"
    else:
        sentiment = "부정적 😞"
        
    return {
        "text": request.text,
        "label": results[0]['label'],
        "sentiment": sentiment,
        "confidence": round(results[0]['score'], 4)
    }

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000)