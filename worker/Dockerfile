FROM python:3.11-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 10001 dakiya && \
    useradd -u 10001 -g dakiya -s /bin/sh -m dakiya

COPY --from=builder /install /usr/local
COPY worker.py .

RUN chown -R dakiya:dakiya /app

USER 10001

CMD ["python", "worker.py"]