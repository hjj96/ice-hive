#!/usr/bin/env python3
"""diet.py <results dir>: shrinks a CI result set before the report job commits it to ci-results (Stage 2 C2 «CI results
diet»; the repo nears its size quota and a full set was ~765 MB: 82 shot PNGs 332 MB, 29 other-phone PNGs 63 MB, 490 burst
frames 357 MB). Every gate has already run on the originals inside the jobs; this only changes what is published.

  shots   every <name>.png → <name>.jpg (same basename): JPEG quality 90 with 4:4:4 chroma — HUD text, thin lines and the
          swarm's single-pixel pores stay as in the PNG at 100 % crops (4:2:0 softened the coloured glyph edges and pores);
          ≈ 6–7× smaller
  bursts  every burst-<name>-NN.jpg sequence → burst-<name>.mp4: H.264 (libx264, CRF 23, preset medium), yuv420p, even
          dimensions (padded, never scaled), 6 frames/s, one video frame per burst frame — burst frame NN is video frame
          NN (0-based), so `ffmpeg -i burst-<name>.mp4 -start_number 0 burst-<name>-%02d.png` gives the frames back under
          their names; faststart for browsers; ≈ 8× smaller than the JPEG frames

It never loses a result: an original is removed only after its replacement was written and read back (the JPEG decoded at
the same size, the MP4 decoded to the same number of frames); any failure keeps the originals and prints a ::warning::.
It always exits 0. ffmpeg: $DIET_FFMPEG, else `ffmpeg` on PATH with libx264, else imageio-ffmpeg's bundled binary."""
import os
import re
import shutil
import subprocess
import sys
import tempfile

JPEG_QUALITY = 90
CRF = 23
FPS = 6
rx_burst = re.compile(r'^burst-(.+)-(\d{2,3})\.jpg$')


def warn(msg):
    print(f'::warning::diet: {msg}', flush=True)


def has_x264(exe):
    try:
        out = subprocess.run([exe, '-hide_banner', '-encoders'], capture_output=True, text=True, timeout=60).stdout
        return ' libx264 ' in out
    except Exception:
        return False


def find_ffmpeg():
    for exe in (os.environ.get('DIET_FFMPEG'), shutil.which('ffmpeg')):
        if exe and has_x264(exe):
            return exe
    try:
        import imageio_ffmpeg
        exe = imageio_ffmpeg.get_ffmpeg_exe()
        if has_x264(exe):
            return exe
    except Exception:
        pass
    return None


def mb(n):
    return f'{n / 1e6:.1f} MB'


def shots(res):
    """PNG → JPEG; returns (converted, kept, bytes before, bytes after)"""
    try:
        from PIL import Image
    except Exception as e:
        warn(f'no Pillow ({e}): the shots stay PNG')
        return 0, 0, 0, 0
    done = kept = before = after = 0
    for name in sorted(os.listdir(res)):
        if not name.endswith('.png'):
            continue
        src = os.path.join(res, name)
        dst = os.path.join(res, name[:-4] + '.jpg')
        if not os.path.isfile(src):
            continue
        if os.path.exists(dst):
            warn(f'{name}: {os.path.basename(dst)} exists already — kept as PNG')
            kept += 1
            continue
        part = dst + '.part'
        try:
            with Image.open(src) as im:
                size = im.size
                im.convert('RGB').save(part, 'JPEG', quality=JPEG_QUALITY, subsampling=0, optimize=True)
            with Image.open(part) as back:
                back.load()
                if back.size != size:
                    raise ValueError(f'read back at {back.size}, not {size}')
            n0, n1 = os.path.getsize(src), os.path.getsize(part)
            os.replace(part, dst)
            os.remove(src)
            done += 1
            before += n0
            after += n1
        except Exception as e:
            warn(f'{name}: {e} — kept as PNG')
            kept += 1
            if os.path.exists(part):
                os.remove(part)
    return done, kept, before, after


def count_frames(ffmpeg, path):
    """frames decoded from the file's video stream (ffmpeg's -progress report), or -1"""
    try:
        p = subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-nostats', '-i', path, '-map', '0:v:0', '-f', 'null',
                            '-progress', 'pipe:1', '-'], capture_output=True, text=True, timeout=300)
        frames = [int(l.split('=', 1)[1]) for l in p.stdout.splitlines() if l.startswith('frame=')]
        return frames[-1] if p.returncode == 0 and frames else -1
    except Exception:
        return -1


def bursts(res, ffmpeg):
    """burst-<name>-NN.jpg sequences → burst-<name>.mp4; returns (encoded, kept, frames, bytes before, bytes after)"""
    groups = {}
    for name in os.listdir(res):
        m = rx_burst.match(name)
        if m:
            groups.setdefault(m.group(1), []).append((int(m.group(2)), name))
    if groups and not ffmpeg:
        warn('no ffmpeg with libx264: the burst frames stay JPEG')
        return 0, len(groups), 0, 0, 0
    done = kept = nframes = before = after = 0
    for b in sorted(groups):
        frames = sorted(groups[b])
        out = os.path.join(res, f'burst-{b}.mp4')
        if [k for k, _ in frames] != list(range(len(frames))):
            warn(f'burst {b}: frames {[k for k, _ in frames]} are not 0..{len(frames) - 1} — kept as JPEG')
            kept += 1
            continue
        if os.path.exists(out):
            warn(f'burst {b}: {os.path.basename(out)} exists already — kept as JPEG')
            kept += 1
            continue
        part = out + '.part'
        tmp = tempfile.mkdtemp(prefix=f'diet-{b}-')
        try:
            for i, (_, name) in enumerate(frames):
                os.symlink(os.path.abspath(os.path.join(res, name)), os.path.join(tmp, f'f{i:05d}.jpg'))
            cmd = [ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-framerate', str(FPS), '-start_number', '0',
                   '-i', os.path.join(tmp, 'f%05d.jpg'), '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2', '-c:v', 'libx264',
                   '-preset', 'medium', '-crf', str(CRF), '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
                   '-metadata', f'comment=CI burst {b}: video frame N is burst frame N (0-based), {FPS} frames/s',
                   '-f', 'mp4', part]
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
            if p.returncode != 0:
                raise RuntimeError(f'ffmpeg exit {p.returncode}: {p.stderr.strip()[-300:]}')
            got = count_frames(ffmpeg, part)
            if got != len(frames):
                raise RuntimeError(f'the MP4 decodes to {got} frames, not {len(frames)}')
            n0 = sum(os.path.getsize(os.path.join(res, name)) for _, name in frames)
            n1 = os.path.getsize(part)
            os.replace(part, out)
            for _, name in frames:
                os.remove(os.path.join(res, name))
            done += 1
            nframes += len(frames)
            before += n0
            after += n1
        except Exception as e:
            warn(f'burst {b}: {e} — kept as JPEG')
            kept += 1
            if os.path.exists(part):
                os.remove(part)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return done, kept, nframes, before, after


def folder_bytes(res):
    return sum(os.path.getsize(os.path.join(res, n)) for n in os.listdir(res) if os.path.isfile(os.path.join(res, n)))


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        warn(f'usage: diet.py <results dir> (got {sys.argv[1:]}) — nothing changed')
        return
    res = sys.argv[1]
    total0 = folder_bytes(res)
    s = shots(res)
    ffmpeg = find_ffmpeg()
    b = bursts(res, ffmpeg)
    total1 = folder_bytes(res)
    print(f'diet: shots {s[0]} PNG → JPEG q{JPEG_QUALITY} 4:4:4 ({mb(s[2])} → {mb(s[3])})' + (f', {s[1]} kept as PNG' if s[1] else ''))
    print(f'diet: bursts {b[0]} ({b[2]} frames) → H.264 CRF {CRF} ({mb(b[3])} → {mb(b[4])})' + (f', {b[1]} kept as JPEG' if b[1] else '')
          + (f' [ffmpeg {ffmpeg}]' if ffmpeg else ''))
    print(f'diet: the result set {mb(total0)} → {mb(total1)} ({len(os.listdir(res))} files)')


if __name__ == '__main__':
    try:
        main()
    except Exception as e:  # never fail the job: the originals stay where the step stopped
        warn(f'stopped: {e} — the rest of the results keep their originals')
    sys.exit(0)
