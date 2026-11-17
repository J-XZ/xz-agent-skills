#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [--prefix DIR] [--link DIR]...

Copy skills to PREFIX/.agents/skills and optionally link them into DIR.
Default PREFIX: ${XDG_DATA_HOME:-$HOME/.local/share}/xz-agent-skills

  --prefix DIR  Set the local installation root.
  --link DIR    Link installed skills into this skills directory (repeatable).
  -h, --help    Show this help.

Existing unmanaged content is never overwritten. Run again to update skills.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

prefix="${XDG_DATA_HOME:-${HOME:?HOME is required}/.local/share}/xz-agent-skills"
links=()
while (($#)); do
  case "$1" in
    --prefix|--link)
      (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || die "$1 requires a directory"
      if [[ "$1" == --prefix ]]; then prefix="$2"; else links+=("$2"); fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source_dir="$(cd -- "$script_dir/../.agents/skills" && pwd -P)"
shopt -s nullglob
sources=("$source_dir"/*)
((${#sources[@]})) || die "No skills found in $source_dir"
for source in "${sources[@]}"; do
  name="${source##*/}"
  [[ -d "$source" && ! -L "$source" && -f "$source/SKILL.md" ]] || die "Invalid skill directory: $source"
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#name} -le 64 ]] || die "Invalid skill name: $name"
  declared="$(awk 'NR == 1 { if ($0 != "---") exit; next } /^---$/ { exit } sub(/^name:[ \t]*/, "") { print; exit }' "$source/SKILL.md")"
  [[ "$declared" == "$name" ]] || die "Frontmatter name '$declared' does not match directory: $source"
done

mkdir -p -- "$prefix"
prefix="$(cd -- "$prefix" && pwd -P)"
destination="$prefix/.agents/skills"
case "$destination/" in "$source_dir/"*) die "Installation must be outside the source skills directory" ;; esac
mkdir -p -- "$destination"
destination="$(cd -- "$destination" && pwd -P)"
case "$destination/" in "$source_dir/"*) die "Installation resolves into the source skills directory" ;; esac

lock="$prefix/.install-lock"
mkdir -- "$lock" 2>/dev/null || die "Installation locked: $lock (if interrupted, verify no installer is running before removing it)"
stage=''
cleanup() {
  if [[ -n "$stage" && -d "$stage" ]]; then rm -rf -- "$stage"; fi
  rmdir -- "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage="$(mktemp -d "$destination/.install-XXXXXXXX")"
mkdir -- "$stage/.previous"

for source in "${sources[@]}"; do
  name="${source##*/}"
  target="$destination/$name"
  mkdir -- "$stage/$name"
  cp -R -- "$source/." "$stage/$name/"
  printf 'xz-agent-skills:%s\n' "$name" > "$stage/$name/.xz-agent-skills-managed"
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -d "$target" && ! -L "$target" && -f "$target/.xz-agent-skills-managed" ]] || die "Unmanaged destination: $target"
    cmp -s -- "$stage/$name/.xz-agent-skills-managed" "$target/.xz-agent-skills-managed" || die "Invalid ownership marker: $target"
  fi
done

resolved_links=()
for link_dir in "${links[@]}"; do
  mkdir -p -- "$link_dir"
  link_dir="$(cd -- "$link_dir" && pwd -P)"
  case "$link_dir/" in
    "$source_dir/"*|"$destination/"*) die "Link directory must be outside source and installed skills: $link_dir" ;;
  esac
  for source in "${sources[@]}"; do
    name="${source##*/}"
    link="$link_dir/$name"
    if [[ -e "$link" || -L "$link" ]]; then
      [[ -L "$link" && "$(readlink -- "$link")" == "$destination/$name" ]] || die "Link conflict: $link"
    fi
  done
  resolved_links+=("$link_dir")
done

for source in "${sources[@]}"; do
  name="${source##*/}"
  target="$destination/$name"
  if [[ -d "$target" ]]; then
    if diff -qr -- "$stage/$name" "$target" >/dev/null; then
      printf 'Unchanged: %s\n' "$name"
      continue
    fi
    mv -- "$target" "$stage/.previous/$name"
    if ! mv -- "$stage/$name" "$target"; then
      mv -- "$stage/.previous/$name" "$target"
      die "Could not update $name"
    fi
    printf 'Updated: %s\n' "$name"
  else
    mv -- "$stage/$name" "$target"
    printf 'Installed: %s\n' "$name"
  fi
done

for installed in "$destination"/*/; do
  installed="${installed%/}"
  name="${installed##*/}"
  [[ -d "$source_dir/$name" || ! -f "$installed/.xz-agent-skills-managed" ]] && continue
  printf 'xz-agent-skills:%s\n' "$name" | cmp -s - "$installed/.xz-agent-skills-managed" || continue
  mv -- "$installed" "$stage/.previous/$name"
  printf 'Removed: %s\n' "$name"
  for link_dir in "${resolved_links[@]}"; do
    link="$link_dir/$name"
    if [[ -L "$link" && "$(readlink -- "$link")" == "$installed" ]]; then
      rm -- "$link"
      printf 'Unlinked: %s\n' "$link"
    fi
  done
done

for link_dir in "${resolved_links[@]}"; do
  for source in "${sources[@]}"; do
    name="${source##*/}"
    link="$link_dir/$name"
    if [[ ! -L "$link" ]]; then
      ln -s -- "$destination/$name" "$link"
      printf 'Linked: %s\n' "$link"
    fi
  done
done
printf 'Skills available at %s\n' "$destination"
