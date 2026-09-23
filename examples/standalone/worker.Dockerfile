FROM python:3.13-slim

RUN groupadd --system --gid 10001 tay \
    && useradd --system --uid 10002 --gid tay --create-home worker
WORKDIR /app
COPY clients/python /tmp/tay-client
RUN python -m pip install --no-cache-dir /tmp/tay-client && rm -rf /tmp/tay-client
COPY --chown=worker:worker examples/standalone/worker.py ./worker.py
COPY --chown=worker:worker examples/standalone/smoke_client.py ./smoke_client.py
USER 10002:10001
CMD ["python", "-m", "tay", "worker:tay"]
