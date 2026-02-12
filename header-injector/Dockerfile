FROM python:3.11-slim

WORKDIR /app

COPY header-injector/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY header-injector/ /app/

EXPOSE 8089

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8089"]
