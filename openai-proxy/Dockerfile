FROM python:3.11-slim

WORKDIR /app

COPY openai-proxy/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY openai-proxy/ /app/
COPY common/ /app/common/

EXPOSE 8088

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8088"]
