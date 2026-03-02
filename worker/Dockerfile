FROM python:latest

RUN apt-get update && apt-get install -y gcc vim curl

WORKDIR /app
COPY . .
RUN pip install -r requirements.txt

CMD ["python", "worker.py"]
