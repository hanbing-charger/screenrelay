import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZIP_DEFLATED, ZipFile

PACKAGING = Path(__file__).resolve().parent
DESKTOP = PACKAGING.parent
TARGETS = [
    ("macOS-arm64", "darwin", "arm64"),
    ("macOS-x64", "darwin", "amd64"),
    ("Windows-arm64", "windows", "arm64"),
    ("Windows-x64", "windows", "amd64"),
]


def package(target, output_directory):
    name, operating_system, architecture = target
    binary_name = "ScreenRelay.exe" if operating_system == "windows" else "ScreenRelay"
    env = dict(os.environ, CGO_ENABLED="0", GOOS=operating_system, GOARCH=architecture)
    with TemporaryDirectory(prefix="screenrelay-build-") as directory:
        binary = Path(directory) / binary_name
        subprocess.run(
            ["go", "build", "-buildvcs=false", "-p", "2", "-trimpath",
             "-ldflags=-s -w", "-o", binary, "."],
            cwd=DESKTOP, env=env, check=True,
        )
        binary.chmod(0o755)
        archive_path = output_directory / f"ScreenRelay-{name}.zip"
        with ZipFile(archive_path, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
            archive.write(binary, binary.name)
            archive.write(PACKAGING / "使用说明.txt", "使用说明.txt")
            if operating_system == "darwin":
                archive.write(PACKAGING / "启动截屏快传.command", "启动截屏快传.command")
        with ZipFile(archive_path) as archive:
            if archive.testzip() is not None:
                raise RuntimeError(f"Invalid archive: {archive_path}")
        return archive_path


def main():
    output_directory = Path(sys.argv[1]).resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=4) as workers:
        for archive_path in workers.map(lambda target: package(target, output_directory), TARGETS):
            print(archive_path.name)


if __name__ == "__main__":
    main()
