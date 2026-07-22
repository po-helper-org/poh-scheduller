FROM python:3.12-slim

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY sync.py /app/sync.py
COPY sync-loop.sh /app/sync-loop.sh
WORKDIR /app

# default: one-shot sync. Compose overrides entrypoint with sync-loop.sh for the daemon.
ENTRYPOINT ["python", "/app/sync.py"]
