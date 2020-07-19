#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys


def get_git_tags():
    return subprocess.check_output(["git", "tag"], timeout=1).decode().splitlines()


def validate_version(version):
    match = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*$)").match(version)
    if not match:
        raise Exception(f"{version} is not a valid version")


if __name__ == "__main__":
    os.chdir(sys.path[0])

    package_json_file_path = "../package.json"
    print(f"Fetching version from {package_json_file_path}")
    with open(package_json_file_path) as package_json_fp:
        package_json = json.load(package_json_fp)
        version = package_json["version"]

    print(f"Version found in {package_json_file_path} is {version}")
    validate_version(version)

    print(f"Fetching tags from git")
    tags = get_git_tags()

    print(f"Checking new version against previous versions")
    if version in tags:
        raise Exception(f"{version} already exists as a tag")

    print(f"Checking that git working directory is clean")
    git_status_porcelain_output = subprocess.check_output(["git", "status", "--porcelain"], timeout=1).decode()
    if git_status_porcelain_output:
        raise Exception(
            f"You have uncommitted changes or untracked files in your working directory:\n"
            f"{git_status_porcelain_output}"
        )

    print(f"Creating git tag {version} (git tag '{version}')")
    git_tag_version_output = subprocess.check_output(["git", "tag", version], timeout=1).decode()
    print(git_tag_version_output)

    print(f"Pushing git commits (git push)")
    git_push_output = subprocess.check_output(["git", "push"], timeout=15).decode()
    print(git_push_output)

    print(f"Pushing git tags (git push --tags)")
    git_push_tags_output = subprocess.check_output(["git", "push", "--tags"], timeout=15).decode()
    print(git_push_tags_output)

    print("Done")

