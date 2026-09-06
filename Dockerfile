FROM public.ecr.aws/docker/library/python:3.12-alpine
WORKDIR /app
COPY app.py /app/app.py
RUN mkdir -p /data
ENV PORT=8080 DATA_DIR=/data APP_VERSION=v1
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O - http://127.0.0.1:8080/ >/dev/null || exit 1
CMD ["python", "/app/app.py"]
