FROM node:24-alpine AS frontend
WORKDIR /build
COPY frontend/package*.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

FROM python:3.13-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 CONFIG_DIR=/config
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY pyproject.toml uv.lock requirements.lock ./
COPY backend ./backend
RUN pip install --no-cache-dir -r requirements.lock && pip install --no-cache-dir --no-deps . && groupadd -g 10001 intake && useradd -u 10001 -g intake -M intake && mkdir /config && chown intake:intake /config
COPY --from=frontend /build/dist ./frontend/dist
USER 10001:10001
VOLUME ["/config"]
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"
CMD ["uvicorn", "backend.app:app", "--host", "0.0.0.0", "--port", "8000", "--no-proxy-headers"]
