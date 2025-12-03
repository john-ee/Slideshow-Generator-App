# Slideshow Generator App

## Description

A self hosted web app that accesses your picture gallery -pictures and videos- as read only and lets you generate slideshow videos.

## Features

- Thumbnail view of your gallery
- Adds music based on a youtube link
- Select the section on the youtbe video
- Choose the orientation between landscape, portrait and square
- Discord notification via webhook
- Fade in/fade out and duration of the fade
- Generation down in the background
- Job history
- You can set the duration of the image
- Mobile friendly

## Installation

1. Clone the repository:
```bash
git clone https://github.com/john-ee/Slideshow-Generator-App.git
cd Slideshow-Generator-App
```

2. Edit the `docker-compose.yml` file:
```bash
nano docker-compose.yml
```

3. Update the settings to fit your need:
```yaml
volumes:
  - /path/to/your/photos:/media:ro  # Change this to your actual photos directory
environment:
  - DISCORD_WEBHOOK_URL=<url>

```

4. Build and start the container:
```bash
docker-compose up -d
```

5. Access the web application:
```
http://localhost:5000
```

## Potential Issues
* No cleanup job is configured in the Docker container. I set a cron job on my NAS to clean it up

## Screenshot
TODO