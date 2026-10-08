"""
Anti-Copyright Core Video & Audio Engine (Reference)
====================================================
This is the core Python/FFmpeg logic provided in video_processor.py.
The Flutter app executes this exact command structure via ffmpeg_kit_flutter_full_gpl.
"""

FFMPEG_VIDEO_FILTER = (
    "crop=trunc(iw*0.96/2)*2:trunc(ih*0.96/2)*2,"
    "eq=contrast=1.04:saturation=1.03:brightness=0.01,"
    "vignette=PI/5,"
    "noise=alls=3:allf=t+u"
)

FFMPEG_AUDIO_FILTER = (
    "asetrate=44100*1.025,aresample=44100,"
    "atempo=1.015,"
    "equalizer=f=300:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1:g=1,"
    "acompressor=threshold=-12dB:ratio=3:attack=10:release=100"
)

FFMPEG_ENCODING_ARGS = [
    "-c:v", "libx264",
    "-pix_fmt", "yuv420p",
    "-c:a", "aac",
    "-b:a", "192k",
    "-movflags", "+faststart",
    "-preset", "ultrafast"
]

def build_ffmpeg_command(input_file: str, output_file: str) -> list:
    """Builds the full FFmpeg command for terminal, subprocess, or mobile FFmpegKit."""
    return [
        "ffmpeg", "-y",
        "-i", input_file,
        "-vf", FFMPEG_VIDEO_FILTER,
        "-af", FFMPEG_AUDIO_FILTER,
        *FFMPEG_ENCODING_ARGS,
        output_file
    ]
