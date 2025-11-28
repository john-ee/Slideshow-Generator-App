FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    libimage-exiftool-perl \
    bc \
    wget \
    libjpeg-dev \
    zlib1g-dev \
    jq \
    && rm -rf /var/lib/apt/lists/*

RUN wget -O /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp && \
    chmod a+rx /usr/local/bin/yt-dlp

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY slideshow-generator.sh .
COPY templates/ templates/

RUN chmod +x slideshow-generator.sh
RUN mkdir -p /app/work /app/outputs /app/thumbnails /app/status

EXPOSE 5000

CMD ["python", "app.py"]