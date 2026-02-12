FROM python:3.11-slim

WORKDIR /app

COPY usage-writer/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY usage-writer/ /app/
COPY common/ /app/common/

EXPOSE 8091

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8091"]
