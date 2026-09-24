# Standard library only: nothing to pip install, nothing to patch but Python.
FROM python:3.12.14-slim-trixie

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY exporter.py .

# Non-root runtime user (numeric UID so Kubernetes/ECS can verify it).
RUN useradd --no-create-home --uid 1000 appuser
USER 1000

EXPOSE 9542
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:9542/health', timeout=2).status == 200 else 1)"]
CMD ["python", "exporter.py"]
