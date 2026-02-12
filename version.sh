#!/bin/bash
current_version=$(grep -oP '\.version = "\K[^"]+' build.zig.zon)

IFS='.' read -r major minor patch <<< "$current_version"
case "$1" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
new_version="$major.$minor.$patch"

sed -i "s/\.version = \"[^\"]*\"/.version = \"$new_version\"/" build.zig.zon
echo $new_version
