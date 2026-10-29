FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

RUN groupadd -r -g 10001 app && useradd -r -u 10001 -g app -s /usr/sbin/nologin app

WORKDIR /app
COPY --chown=app:app vision_api/ vision_api/
COPY --chown=app:app inference_worker/ inference_worker/

USER 10001:10001
EXPOSE 8000
CMD ["python", "vision_api/app.py"]
