from flask import Flask, render_template, request, jsonify, send_file
import os
import json
import subprocess
import shutil
import threading
from datetime import datetime
from PIL import Image
import requests

app = Flask(__name__)

# Configuration
MEDIA_ROOT = os.environ.get('MEDIA_ROOT', '/media')
WORK_DIR = '/app/work'
OUTPUT_DIR = '/app/outputs'
THUMBNAIL_DIR = '/app/thumbnails'
STATUS_DIR = '/app/status'
os.makedirs(WORK_DIR, exist_ok=True)
os.makedirs(OUTPUT_DIR, exist_ok=True)
os.makedirs(THUMBNAIL_DIR, exist_ok=True)
os.makedirs(STATUS_DIR, exist_ok=True)

job_statuses = {}
THUMBNAIL_SIZE = (400, 300)
THUMBNAIL_QUALITY = 85

DISCORD_WEBHOOK_URL = os.environ.get('DISCORD_WEBHOOK_URL')

# Send a notification via Discord hook
def notify_discord(job_id, status, message, output_file=None):
    if not DISCORD_WEBHOOK_URL:
        return
    content = f"**Slideshow Job {job_id}**\nStatus: {status}\nMessage: {message}"
    if output_file:
        content += f"\nOutput: {output_file}"
    try:
        requests.post(DISCORD_WEBHOOK_URL, json={"content": content})
    except Exception as e:
        print(f"Discord notification failed: {e}")


# Save job statuses to disk for persistence
def save_job_status(job_id):
    try:
        status_file = os.path.join(STATUS_DIR, f'{job_id}.json')
        with open(status_file, 'w') as f:
            json.dump(job_statuses[job_id], f)
    except Exception as e:
        print(f"Error saving job status: {e}")

def load_job_statuses():
    """Load all job statuses from disk on startup"""
    try:
        for filename in os.listdir(STATUS_DIR):
            if filename.endswith('.json'):
                job_id = filename[:-5]
                with open(os.path.join(STATUS_DIR, filename), 'r') as f:
                    job_statuses[job_id] = json.load(f)
    except Exception as e:
        print(f"Error loading job statuses: {e}")

# Load existing jobs on startup
load_job_statuses()

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/jobs')
def jobs_page():
    return render_template('jobs.html')

@app.route('/api/browse')
def browse_folders():
    try:
        path = request.args.get('path', '')
        full_path = os.path.join(MEDIA_ROOT, path)
        
        if not os.path.exists(full_path) or not full_path.startswith(MEDIA_ROOT):
            return jsonify({'error': 'Invalid path'}), 400
        
        items = []
        for item in sorted(os.listdir(full_path)):
            item_path = os.path.join(full_path, item)
            rel_path = os.path.relpath(item_path, MEDIA_ROOT)
            
            if os.path.isdir(item_path):
                items.append({
                    'name': item,
                    'type': 'folder',
                    'path': rel_path
                })
        
        return jsonify({
            'current_path': path,
            'items': items
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/list-media')
def list_media():
    try:
        path = request.args.get('path', '')
        page = int(request.args.get('page', 1))
        per_page = int(request.args.get('per_page', 50))
        
        full_path = os.path.join(MEDIA_ROOT, path)
        
        if not os.path.exists(full_path) or not full_path.startswith(MEDIA_ROOT):
            return jsonify({'error': 'Invalid path'}), 400
        
        supported_extensions = {'.jpg', '.jpeg', '.png', '.gif', '.mp4', '.mov', '.avi', '.mkv'}
        
        all_files = []
        for item in sorted(os.listdir(full_path)):
            item_path = os.path.join(full_path, item)
            if os.path.isfile(item_path):
                ext = os.path.splitext(item)[1].lower()
                if ext in supported_extensions:
                    rel_path = os.path.relpath(item_path, MEDIA_ROOT)
                    all_files.append({
                        'name': item,
                        'path': rel_path,
                        'type': 'video' if ext in {'.mp4', '.mov', '.avi', '.mkv'} else 'image'
                    })
        
        total = len(all_files)
        start = (page - 1) * per_page
        end = start + per_page
        paginated_files = all_files[start:end]
        
        return jsonify({
            'media': paginated_files,
            'total': total,
            'page': page,
            'per_page': per_page,
            'total_pages': (total + per_page - 1) // per_page
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

def generate_thumbnail(source_path):
    try:
        rel_path = os.path.relpath(source_path, MEDIA_ROOT)
        thumb_path = os.path.join(THUMBNAIL_DIR, rel_path + '.thumb.jpg')
        
        os.makedirs(os.path.dirname(thumb_path), exist_ok=True)
        
        if os.path.exists(thumb_path):
            if os.path.getmtime(thumb_path) >= os.path.getmtime(source_path):
                return thumb_path
        
        with Image.open(source_path) as img:
            if img.mode in ('RGBA', 'LA', 'P'):
                background = Image.new('RGB', img.size, (255, 255, 255))
                if img.mode == 'P':
                    img = img.convert('RGBA')
                background.paste(img, mask=img.split()[-1] if img.mode in ('RGBA', 'LA') else None)
                img = background
            
            img.thumbnail(THUMBNAIL_SIZE, Image.Resampling.LANCZOS)
            img.save(thumb_path, 'JPEG', quality=THUMBNAIL_QUALITY, optimize=True)
        
        return thumb_path
    except Exception as e:
        print(f"Error generating thumbnail: {e}")
        return None

@app.route('/api/thumbnail/<path:filepath>')
def serve_thumbnail(filepath):
    try:
        full_path = os.path.join(MEDIA_ROOT, filepath)
        if not full_path.startswith(MEDIA_ROOT) or not os.path.exists(full_path):
            return 'File not found', 404
        
        ext = os.path.splitext(filepath)[1].lower()
        if ext in {'.mp4', '.mov', '.avi', '.mkv'}:
            return send_file(full_path)
        
        thumb_path = generate_thumbnail(full_path)
        if thumb_path and os.path.exists(thumb_path):
            return send_file(thumb_path, mimetype='image/jpeg')
        else:
            return send_file(full_path)
            
    except Exception as e:
        return str(e), 500

@app.route('/api/media/<path:filepath>')
def serve_media(filepath):
    try:
        full_path = os.path.join(MEDIA_ROOT, filepath)
        if not full_path.startswith(MEDIA_ROOT) or not os.path.exists(full_path):
            return 'File not found', 404
        return send_file(full_path)
    except Exception as e:
        return str(e), 500

@app.route('/api/generate', methods=['POST'])
def generate_slideshow():
    try:
        data = request.json
        selected_files = data.get('files', [])
        youtube_url = data.get('youtube_url', '')
        youtube_start = data.get('youtube_start', '')
        youtube_end = data.get('youtube_end', '')
        duration = data.get('duration', 3)
        orientation = data.get('orientation', 'landscape')
        fade_duration = data.get('fade_duration', 2)
        music_volume = data.get('music_volume', 0.3)
        threads = data.get('threads', 2)
        
        if not selected_files:
            return jsonify({'error': 'No files selected'}), 400
        
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        job_id = f'job_{timestamp}'
        
        job_statuses[job_id] = {
            'status': 'queued',
            'progress': 0,
            'message': 'Starting slideshow generation...',
            'output_file': None,
            'error': None,
            'created_at': timestamp,
            'file_count': len(selected_files)
        }
        save_job_status(job_id)
        
        thread = threading.Thread(
            target=process_slideshow,
            args=(job_id, selected_files, youtube_url, youtube_start, youtube_end,
                  duration, orientation, fade_duration, music_volume, threads, timestamp)
        )
        thread.daemon = True
        thread.start()
        
        return jsonify({
            'success': True,
            'job_id': job_id,
            'message': 'Slideshow generation started'
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

def process_slideshow(job_id, selected_files, youtube_url, youtube_start, youtube_end,
                      duration, orientation, fade_duration, music_volume, threads, timestamp):
    job_dir = None
    try:
        job_statuses[job_id]['status'] = 'processing'
        job_statuses[job_id]['progress'] = 10
        job_statuses[job_id]['message'] = 'Copying media files...'
        save_job_status(job_id)
        
        job_dir = os.path.join(WORK_DIR, timestamp)
        media_dir = os.path.join(job_dir, 'media')
        os.makedirs(media_dir, exist_ok=True)
        
        total_files = len(selected_files)
        for i, file_path in enumerate(selected_files):
            src = os.path.join(MEDIA_ROOT, file_path)
            ext = os.path.splitext(file_path)[1]
            dst = os.path.join(media_dir, f'{i:04d}{ext}')
            shutil.copy2(src, dst)
            
            progress = 10 + int((i / total_files) * 20)
            job_statuses[job_id]['progress'] = progress
            job_statuses[job_id]['message'] = f'Copying files... ({i+1}/{total_files})'
            if i % 5 == 0:
                save_job_status(job_id)
        
        job_statuses[job_id]['progress'] = 30
        job_statuses[job_id]['message'] = 'Generating slideshow with ffmpeg...'
        save_job_status(job_id)
        
        output_file = os.path.join(OUTPUT_DIR, f'slideshow_{timestamp}.mp4')
        
        cmd = [
            'bash', '/app/slideshow-generator.sh',
            '-d', media_dir,
            '-f', output_file,
            '-t', str(duration),
            '-o', orientation
        ]
        
        if youtube_url:
            cmd.extend(['-y', youtube_url])
            
            # Add timestamp section if provided
            if youtube_start and youtube_end:
                youtube_section = f"{youtube_start}-{youtube_end}"
                cmd.extend(['-s', youtube_section])
                job_statuses[job_id]['message'] = f'Downloading audio from YouTube ({youtube_start} to {youtube_end})...'
            elif youtube_start:
                youtube_section = f"{youtube_start}-inf"
                cmd.extend(['-s', youtube_section])
                job_statuses[job_id]['message'] = f'Downloading audio from YouTube (from {youtube_start})...'
            else:
                job_statuses[job_id]['message'] = 'Downloading audio from YouTube...'
            
            save_job_status(job_id)
        
        env = os.environ.copy()
        env['THREADS'] = str(threads)
        env['FADE_DUR'] = str(fade_duration)
        env['MUSIC_VOL'] = str(music_volume)
        
        job_statuses[job_id]['progress'] = 40
        job_statuses[job_id]['message'] = 'Processing video (this may take several minutes)...'
        save_job_status(job_id)
        
        result = subprocess.run(
            cmd,
            cwd=job_dir,
            capture_output=True,
            text=True,
            env=env
        )
        
        if result.returncode != 0:
            job_statuses[job_id]['status'] = 'failed'
            job_statuses[job_id]['error'] = result.stderr
            job_statuses[job_id]['message'] = 'Generation failed'
            save_job_status(job_id)
            notify_discord(job_id, 'failed', 'Generation failed')
            return
        
        job_statuses[job_id]['progress'] = 100
        job_statuses[job_id]['status'] = 'completed'
        job_statuses[job_id]['message'] = 'Slideshow generated successfully!'
        job_statuses[job_id]['output_file'] = f'slideshow_{timestamp}.mp4'
        job_statuses[job_id]['completed_at'] = datetime.now().strftime('%Y%m%d_%H%M%S')
        save_job_status(job_id)
        notify_discord(job_id, 'completed', 'Slideshow generated successfully!', job_statuses[job_id]['output_file'])
        
    except Exception as e:
        job_statuses[job_id]['status'] = 'failed'
        job_statuses[job_id]['error'] = str(e)
        job_statuses[job_id]['message'] = f'Error: {str(e)}'
        save_job_status(job_id)
    finally:
        if job_dir and os.path.exists(job_dir):
            try:
                shutil.rmtree(job_dir)
            except:
                pass

@app.route('/api/jobs')
def list_jobs():
    jobs = []
    for job_id, status in job_statuses.items():
        jobs.append({
            'job_id': job_id,
            **status
        })
    jobs.sort(key=lambda x: x.get('created_at', ''), reverse=True)
    return jsonify({'jobs': jobs})

@app.route('/api/status/<job_id>')
def get_job_status(job_id):
    if job_id not in job_statuses:
        return jsonify({'error': 'Job not found'}), 404
    return jsonify(job_statuses[job_id])

@app.route('/api/download/<filename>')
def download(filename):
    try:
        file_path = os.path.join(OUTPUT_DIR, filename)
        if not os.path.exists(file_path):
            return 'File not found', 404
        return send_file(file_path, as_attachment=True)
    except Exception as e:
        return str(e), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)