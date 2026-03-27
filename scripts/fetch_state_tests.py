#!/usr/bin/env python3

import argparse
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import Optional


DEFAULT_URL = (
    "https://raw.githubusercontent.com/ethereum/tests/develop/"
    "fixtures_general_state_tests.tgz"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download and extract official ethereum/tests GeneralStateTests fixtures"
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help="Fixture tarball URL (default: %(default)s)",
    )
    parser.add_argument(
        "--dest",
        default="test/fixtures/state_tests/official",
        help="Destination directory inside the repo (default: %(default)s)",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Delete the destination directory before extraction",
    )
    parser.add_argument(
        "--strip-components",
        type=int,
        default=1,
        help="Strip leading path components while extracting (default: %(default)s)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would happen without writing files",
    )
    return parser.parse_args()


def strip_path(path: str, components: int) -> Optional[Path]:
    parts = Path(path).parts
    if len(parts) <= components:
        return None
    return Path(*parts[components:])


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    dest = (repo_root / args.dest).resolve()

    print(f"Downloading {args.url}")

    with tempfile.TemporaryDirectory() as temp_dir:
        archive_path = Path(temp_dir) / "fixtures_general_state_tests.tgz"
        urllib.request.urlretrieve(args.url, archive_path)

        if args.clean and dest.exists():
            print(f"Removing {dest}")
            if not args.dry_run:
                shutil.rmtree(dest)

        if not args.dry_run:
            dest.mkdir(parents=True, exist_ok=True)

        with tarfile.open(archive_path, "r:gz") as archive:
            members = [member for member in archive.getmembers() if member.isfile()]

            for member in members:
                relative = strip_path(member.name, args.strip_components)
                if relative is None:
                    continue

                target = dest / relative
                print(f"Extracting {relative}")

                if args.dry_run:
                    continue

                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise RuntimeError(f"Failed to extract {member.name}")

                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)

    print(f"Fixtures ready in {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
