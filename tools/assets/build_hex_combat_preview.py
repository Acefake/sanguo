"""Package actual-map captures of bounded volleys and directional siege actions."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FRAMES = ROOT / "docs/validation/hex-combat-readability-2026-10-07"
FFMPEG = Path(r"C:\ffmpeg-2026-04-19-git-de18feb0f0-full_build\bin\ffmpeg.exe")

if __name__ == "__main__":
    sequences = ["arrows-38", "arrows-75", "siege", "city-38", "city-75"]
    for name in sequences:
        assert all((FRAMES / f"{name}-{i:02d}.png").is_file() for i in range(24)), name
        subprocess.run([
            str(FFMPEG), "-y", "-loglevel", "error", "-stream_loop", "1",
            "-framerate", "12", "-i", str(FRAMES / f"{name}-%02d.png"),
            "-t", "4", "-an", "-c:v", "libx264", "-crf", "20",
            "-pix_fmt", "yuv420p", "-r", "30", str(FRAMES / f"{name}.mp4")
        ], check=True, creationflags=0x08000000)
    parts = FRAMES / "video-parts.txt"
    parts.write_text("".join(f"file '{name}.mp4'\n" for name in sequences), encoding="utf-8")
    target = ROOT / "docs/validation/格内射击与兵器朝向预览-2026-10-07.mp4"
    subprocess.run([
        str(FFMPEG), "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
        "-i", str(parts), "-c", "copy", "-movflags", "+faststart", str(target)
    ], check=True, creationflags=0x08000000)
    print("HEX_COMBAT_PREVIEW_OK", target, flush=True)
