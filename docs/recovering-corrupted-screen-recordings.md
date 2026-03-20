# Recovering Corrupted Screen Recordings (Missing moov Atom)

When `gpu-screen-recorder` is killed without a clean shutdown (e.g., SIGKILL, process crash, or the stderr pipe deadlock bug fixed in commit 7bde9a3), the resulting MP4 files are missing their `moov` atom — the index that tells video players how to read the file. The raw video data in the `mdat` atom is intact but unplayable.

## Symptoms

- Video player shows "file is corrupted" or refuses to open
- `ffprobe` reports: `moov atom not found`
- File has reasonable size (not 0 bytes)

## Prerequisites

- `ffmpeg` and `ffprobe` installed
- `gpu-screen-recorder` installed (to create a reference file)
- `python3`
- Access to the same monitor setup used during the original recording

## Recovery Steps

### 1. Verify the file is recoverable

```bash
ffprobe screen-HDMI-A-1.mp4
# Should show: "moov atom not found" — this confirms the data is there but the index is missing

# Verify the file has actual data (ftyp + mdat atoms)
xxd screen-HDMI-A-1.mp4 | head -5
# Should show: "ftyp" near the start and "mdat" shortly after
```

### 2. Create a reference recording

Record a short (2-3 second) clip on the **same monitor** using the same `gpu-screen-recorder` settings. This provides the SPS/PPS codec headers needed to decode the H.264 stream.

```bash
gpu-screen-recorder -w HDMI-A-1 -f 30 -fallback-cpu-encoding yes -o /tmp/ref_HDMI-A-1.mp4 &
REF_PID=$!
sleep 3
kill -SIGINT $REF_PID
wait $REF_PID 2>/dev/null

# Verify the reference is valid
ffprobe -v error -show_entries stream=width,height -show_entries format=duration \
  -of default=noprint_wrappers=1 /tmp/ref_HDMI-A-1.mp4
```

Repeat for each monitor if recovering multiple files (e.g., `eDP-1`, `DP-1`).

### 3. Extract SPS/PPS and raw H.264 stream, then remux

Run this Python script. It:
1. Extracts SPS (Sequence Parameter Set) and PPS (Picture Parameter Set) from the reference MP4's `avcC` box
2. Converts the broken file's `mdat` from AVCC format (4-byte length-prefixed NAL units) to Annex B format (start code prefixed)
3. Re-injects SPS/PPS before each keyframe so the decoder can resync
4. Uses ffmpeg to remux the raw H.264 stream into a valid MP4

```python
#!/usr/bin/env python3
"""Recover a screen recording MP4 with a missing moov atom."""
import struct
import os
import subprocess
import sys

def extract_sps_pps(ref_path):
    """Extract SPS and PPS NAL units from a working MP4's avcC box."""
    with open(ref_path, 'rb') as f:
        data = f.read()
    avcc_pos = data.find(b'avcC')
    if avcc_pos < 0:
        raise ValueError("No avcC found in reference file")
    pos = avcc_pos + 4 + 5  # skip tag + version/profile/compat/level/lengthSize
    sps_count = data[pos] & 0x1f
    pos += 1
    sps_list = []
    for _ in range(sps_count):
        sps_len = struct.unpack('>H', data[pos:pos+2])[0]
        pos += 2
        sps_list.append(data[pos:pos+sps_len])
        pos += sps_len
    pps_count = data[pos]
    pos += 1
    pps_list = []
    for _ in range(pps_count):
        pps_len = struct.unpack('>H', data[pos:pos+2])[0]
        pos += 2
        pps_list.append(data[pos:pos+pps_len])
        pos += pps_len
    return sps_list, pps_list

def recover(src, dst, ref_path, framerate=30):
    """Recover a corrupted MP4 using a reference file's codec headers."""
    sps_list, pps_list = extract_sps_pps(ref_path)

    with open(src, 'rb') as f:
        data = f.read()

    mdat_pos = data.find(b'mdat')
    if mdat_pos < 0:
        print(f"ERROR: no mdat atom found in {src}")
        return False

    # Convert AVCC (length-prefixed) NAL units to Annex B (start-code prefixed)
    h264_path = dst + '.h264'
    with open(h264_path, 'wb') as out:
        # Write initial SPS/PPS
        for sps in sps_list:
            out.write(b'\x00\x00\x00\x01')
            out.write(sps)
        for pps in pps_list:
            out.write(b'\x00\x00\x00\x01')
            out.write(pps)

        pos = mdat_pos + 4  # skip 'mdat' tag
        count = 0
        while pos < len(data) - 4:
            nal_len = struct.unpack('>I', data[pos:pos+4])[0]
            if nal_len == 0 or nal_len > 10_000_000 or pos + 4 + nal_len > len(data):
                break
            pos += 4
            nal_type = data[pos] & 0x1f

            # Re-inject SPS/PPS before each IDR keyframe
            if nal_type == 5:
                for sps in sps_list:
                    out.write(b'\x00\x00\x00\x01')
                    out.write(sps)
                for pps in pps_list:
                    out.write(b'\x00\x00\x00\x01')
                    out.write(pps)

            out.write(b'\x00\x00\x00\x01')
            out.write(data[pos:pos+nal_len])
            count += 1
            pos += nal_len

    print(f"Extracted {count} NAL units, remuxing...")

    # Remux raw H.264 into a valid MP4 container
    result = subprocess.run(
        ['ffmpeg', '-y', '-fflags', '+genpts', '-r', str(framerate),
         '-f', 'h264', '-i', h264_path,
         '-c', 'copy', '-r', str(framerate),
         '-movflags', '+faststart', dst],
        capture_output=True, text=True
    )
    os.unlink(h264_path)

    if result.returncode == 0 and os.path.exists(dst):
        probe = subprocess.run(
            ['ffprobe', '-v', 'error',
             '-show_entries', 'stream=width,height,duration,nb_frames',
             '-of', 'default=noprint_wrappers=1', dst],
            capture_output=True, text=True)
        print(f"Recovered: {dst}")
        print(probe.stdout.strip())
        return True
    else:
        print(f"FAILED: {result.stderr[-300:]}")
        return False

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <reference.mp4> <corrupted.mp4> <output.mp4> [framerate]")
        print(f"  reference.mp4  - A short working recording from the same monitor/settings")
        print(f"  corrupted.mp4  - The broken file with missing moov atom")
        print(f"  output.mp4     - Where to write the recovered file")
        print(f"  framerate      - Recording framerate (default: 30)")
        sys.exit(1)

    fps = int(sys.argv[4]) if len(sys.argv) > 4 else 30
    recover(sys.argv[2], sys.argv[3], sys.argv[1], fps)
```

### 4. Run the recovery

```bash
# Save the script above as recover_mp4.py, then:
python3 recover_mp4.py /tmp/ref_HDMI-A-1.mp4 screen-HDMI-A-1.mp4 screen-HDMI-A-1_recovered.mp4
```

### 5. Verify the recovered file

```bash
ffprobe -v error \
  -show_entries stream=width,height,duration,nb_frames,codec_name \
  -of default=noprint_wrappers=1 screen-HDMI-A-1_recovered.mp4

# Try playing it
mpv screen-HDMI-A-1_recovered.mp4
# or
vlc screen-HDMI-A-1_recovered.mp4
```

## How It Works

MP4 files have two critical atoms:
- **`mdat`** — the actual video/audio data (H.264 NAL units)
- **`moov`** — the index/metadata (codec config, frame sizes, timestamps, SPS/PPS)

When gpu-screen-recorder is killed uncleanly, `moov` is never written (it's written at the end during finalization). The recovery process:

1. **SPS/PPS extraction**: The H.264 Sequence Parameter Set and Picture Parameter Set contain codec configuration (resolution, profile, level). In MP4 files these are stored in the `moov` atom's `avcC` box, not inline in the stream. We extract them from a reference recording made with identical settings.

2. **AVCC → Annex B conversion**: MP4 stores H.264 NAL units with 4-byte length prefixes (AVCC format). Raw H.264 streams use start codes (`00 00 00 01`) instead (Annex B format). The script converts between these formats.

3. **SPS/PPS injection**: SPS/PPS are injected before each IDR (keyframe) in the stream so the decoder can initialize at any keyframe, not just the start.

4. **Remuxing with ffmpeg**: The raw Annex B stream is fed to ffmpeg which generates proper timestamps (`-fflags +genpts`) at the specified framerate and writes a valid MP4 with a complete `moov` atom.

## Limitations

- The reference recording **must** use the same `gpu-screen-recorder` settings (resolution, framerate, codec, quality) as the corrupted file
- Audio tracks are not recovered (gpu-screen-recorder screen recordings are video-only)
- Frame timestamps are reconstructed assuming constant framerate — minor timing drift is possible
- If the corrupted file was also affected by the stderr pipe deadlock, the video may cover less wall-clock time than the actual meeting duration
