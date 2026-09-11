"""Build a Docker context from canonical checkouts without cloning or copying a repository."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Existing canonical Clusterio source checkout")
parser.add_argument("--build", action="store_true", help="Build both custom images locally")
parser.add_argument("--prefix", default="clusterio-custom", help="Local image tag prefix")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = args.source.resolve()
def git(directory, *command):
    return subprocess.check_output(["git", "-C", str(directory), *command])
assert Path(git(source, "rev-parse", "--show-toplevel").decode().strip()).resolve() == source
output = root / "ci-artifacts" / "custom-context"
output.mkdir(parents=True, exist_ok=True)
archive = output / "context.tar"
source_files = git(source, "ls-files", "-z").decode().split("\0")
# Only build inputs from this repository; no environment files or Docker state.
image_names = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z",
                  "--", "Dockerfile.controller", "Dockerfile.host", "scripts").decode().split("\0")
image_files = [root / name for name in sorted(set(image_names)) if name]
with tarfile.open(archive, "w", format=tarfile.GNU_FORMAT, dereference=False) as tar:
    for file in image_files:
        if file.is_file():
            tar.add(file, arcname=file.relative_to(root).as_posix(), recursive=False)
    for name in source_files:
        if not name:
            continue
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unexpected tracked source path")
        file = source / relative
        if file.is_file() or file.is_symlink():
            tar.add(file, arcname="clusterio/" + relative.as_posix(), recursive=False)
report = {
    "sourceCommit": git(source, "rev-parse", "HEAD").decode().strip(),
    "trackedSourceModified": bool(git(source, "diff", "HEAD", "--name-only")),
    "contextSha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
    "imageSourceCommit": git(root, "rev-parse", "HEAD").decode().strip(),
    "imageSourceModified": bool(git(root, "status", "--porcelain", "--", "Dockerfile.controller", "Dockerfile.host", "scripts")),
    "archive": str(archive),
}
if args.build:
    for role in ("controller", "host"):
        tag = args.prefix + "-" + role
        revision = report["imageSourceCommit"] + ("-dirty" if report["imageSourceModified"] else "")
        # A byte pipe is required: Docker on Windows can misclassify file-backed stdin.
        subprocess.run(["docker", "build", "-f", "Dockerfile." + role,
                        "--build-arg", "CLUSTERIO_TARGET=custom",
                        "--build-arg", "BUILD_REVISION=" + revision,
                        "-t", tag, "-"], input=archive.read_bytes(), check=True)
        report[role + "Image"] = subprocess.check_output(
            ["docker", "image", "inspect", tag, "--format", "{{.Id}}"]).decode().strip()
(output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
print(json.dumps(report, indent=2))
