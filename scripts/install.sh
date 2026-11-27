#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [--special-antigravity] [--link DIR]... [USER HOST]

Install skills to ${XDG_DATA_HOME:-$HOME/.local/share}/xz-agent-skills/.agents/skills
and optionally link them into DIR.
With --special-antigravity, build the Antigravity plugin (skills + OpenCode MCP) at
${XDG_DATA_HOME:-$HOME/.local/share}/xz-agent-skills/special/antigravity/.agents/plugins/xz-agent-skills.

If USER and HOST are provided as the last two arguments, all operations run remotely
over "ssh USER@HOST" (global install and any --link symlinks are created on the remote host).
Otherwise, installation runs on the local machine.

  --special-antigravity
                Install the Antigravity plugin bundle instead of standard skills.
  --link DIR    Must be "<project>/.agents/skills" under an existing project directory (repeatable).
                Standard mode links skills into DIR.
                With --special-antigravity, does NOT install into DIR; instead links
                the plugin into the sibling "<project>/.agents/plugins" directory.
  -h, --help    Show this help.

Existing versions in the global install directory and existing symlinks at --link targets
are overwritten automatically. Non-symlink files or directories at --link targets are never overwritten.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

strip_trailing_slashes() {
  local p="$1"
  while [[ "$p" == */ && "$p" != "/" ]]; do
    p="${p%/}"
  done
  printf '%s' "$p"
}

extract_project_dir_from_skills_link() {
  local raw clean proj
  raw="$1"
  clean="$(strip_trailing_slashes "$raw")"
  if [[ "$clean" == ".agents/skills" ]]; then
    proj="."
  elif [[ "$clean" == */.agents/skills ]]; then
    proj="${clean%/.agents/skills}"
    [[ -n "$proj" && "$proj" != "/" ]] || die "--link must be '<project>/.agents/skills': $raw"
  else
    die "--link directory must end with '.agents/skills' under a project directory: $raw"
  fi
  printf '%s' "$proj"
}

antigravity=false
links=()
positionals=()
while (($#)); do
  if ((${#positionals[@]} == 0)); then
    case "$1" in
      --special-antigravity) antigravity=true; shift; continue ;;
      --link)
        (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || die "$1 requires a directory"
        links+=("$2")
        shift 2
        continue
        ;;
      -h|--help) usage; exit 0 ;;
      -*) die "Unknown argument: $1 (use --help)" ;;
    esac
  else
    case "$1" in
      -*) die "Options must appear before USER HOST: $1 (use --help)" ;;
    esac
  fi
  positionals+=("$1")
  shift
done

remote_user=''
remote_host=''
if ((${#positionals[@]} == 2)); then
  remote_user="${positionals[0]}"
  remote_host="${positionals[1]}"
  [[ -n "$remote_user" && -n "$remote_host" ]] || die "USER and HOST must be non-empty"
elif ((${#positionals[@]} != 0)); then
  die "Remote installation requires both USER and HOST as the last two arguments (use --help)"
fi

project_raw_dirs=()
for link_dir in ${links[@]+"${links[@]}"}; do
  project_raw_dirs+=("$(extract_project_dir_from_skills_link "$link_dir")")
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
source_dir="$(cd -- "$repo_root/agents/skills" && pwd -P)"
special_root="$repo_root/special/antigravity"
special_dir="$special_root/agents/skills"
special_plugin_json="$special_root/plugin.json"
special_mcp_script="$special_root/mcp/opencode_mcp.py"
plugin_name="xz-agent-skills"

if $antigravity; then
  [[ -d "$special_dir" ]] || die "Missing Antigravity skills: $special_dir"
  [[ -f "$special_plugin_json" ]] || die "Missing Antigravity plugin manifest: $special_plugin_json"
  [[ -f "$special_mcp_script" ]] || die "Missing Antigravity MCP server script: $special_mcp_script"
  special_root="$(cd -- "$special_root" && pwd -P)"
  special_dir="$special_root/agents/skills"
  special_plugin_json="$special_root/plugin.json"
  special_mcp_script="$special_root/mcp/opencode_mcp.py"
elif [[ -d "$special_root" ]]; then
  special_root="$(cd -- "$special_root" && pwd -P)"
  special_dir="$special_root/agents/skills"
fi

shopt -s nullglob
sources=("$source_dir"/*)
((${#sources[@]})) || die "No skills found in $source_dir"
for source in "${sources[@]}"; do
  name="${source##*/}"
  [[ -d "$source" && ! -L "$source" && -f "$source/SKILL.md" ]] || die "Invalid skill directory: $source"
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#name} -le 64 ]] || die "Invalid skill name: $name"
  definition="$source/SKILL.md"
  if $antigravity && [[ -f "$special_dir/$name/SKILL.md" ]]; then definition="$special_dir/$name/SKILL.md"; fi
  declared="$(awk 'NR == 1 { if ($0 != "---") exit; next } /^---$/ { exit } sub(/^name:[ \t]*/, "") { print; exit }' "$definition")"
  [[ "$declared" == "$name" ]] || die "Frontmatter name '$declared' does not match directory: $source"
done

if $antigravity; then
  for override in "$special_dir"/*; do
    oname="${override##*/}"
    [[ -d "$override" && ! -L "$override" && -f "$override/SKILL.md" ]] || die "Invalid Antigravity override skill directory: $override"
    [[ -d "$source_dir/$oname" ]] || die "Antigravity override has no matching base skill: $override"
  done
fi

if [[ -n "$remote_user" ]]; then
  command -v ssh >/dev/null 2>&1 || die "ssh is required for remote installation"
  command -v tar >/dev/null 2>&1 || die "tar is required for remote installation"

  remote_args=()
  if $antigravity; then
    remote_args+=(--special-antigravity)
  fi
  for link_dir in ${links[@]+"${links[@]}"}; do
    remote_args+=(--link "$link_dir")
  done

  quoted_args=''
  for arg in ${remote_args[@]+"${remote_args[@]}"}; do
    printf -v quoted_args '%s %q' "$quoted_args" "$arg"
  done

  tar_paths=(scripts/install.sh agents/skills)
  if $antigravity; then
    tar_paths+=(special/antigravity)
  fi

  remote_cmd="set -euo pipefail; tmp=\$(mktemp -d); trap 'rm -rf -- \"\$tmp\"' EXIT; tar -xf - -C \"\$tmp\"; bash \"\$tmp/scripts/install.sh\"${quoted_args}"
  COPYFILE_DISABLE=1 tar -cf - -C "$repo_root" "${tar_paths[@]}" | ssh -- "${remote_user}@${remote_host}" "bash -lc $(printf '%q' "$remote_cmd")"
  exit 0
fi

base_prefix="${XDG_DATA_HOME:-${HOME:?HOME is required}/.local/share}/xz-agent-skills"
mkdir -p -- "$base_prefix"
base_prefix="$(cd -- "$base_prefix" && pwd -P)"
prefix="$base_prefix"
if $antigravity; then
  command -v python3 >/dev/null 2>&1 || die "python3 is required for --special-antigravity"
  prefix="$base_prefix/special/antigravity"
fi

is_managed_skill_symlink() {
  local link="$1"
  local name target
  [[ -L "$link" ]] || return 1
  name="${link##*/}"
  target="$(readlink -- "$link")"
  case "$target" in
    "$base_prefix/.agents/skills/"*|"$base_prefix/special/antigravity/.agents/skills/"*)
      return 0
      ;;
  esac
  if [[ -d "$link" && -f "$link/.xz-agent-skills-managed" ]]; then
    printf 'xz-agent-skills:%s\n' "$name" | cmp -s - "$link/.xz-agent-skills-managed" && return 0
  fi
  return 1
}

is_managed_plugin_symlink() {
  local link="$1"
  local target
  [[ -L "$link" ]] || return 1
  target="$(readlink -- "$link")"
  case "$target" in
    "$base_prefix/special/antigravity/.agents/plugins/$plugin_name")
      return 0
      ;;
  esac
  if [[ -d "$link" && -f "$link/.xz-agent-skills-managed" ]]; then
    printf 'xz-agent-skills:plugin:%s\n' "$plugin_name" | cmp -s - "$link/.xz-agent-skills-managed" && return 0
  fi
  return 1
}

mkdir -p -- "$prefix"
prefix="$(cd -- "$prefix" && pwd -P)"
if $antigravity; then
  destination="$prefix/.agents/plugins"
else
  destination="$prefix/.agents/skills"
fi
case "$destination/" in "$source_dir/"*|"$special_root/"*) die "Installation must be outside the source skills directories" ;; esac
mkdir -p -- "$destination"
destination="$(cd -- "$destination" && pwd -P)"
case "$destination/" in "$source_dir/"*|"$special_root/"*) die "Installation resolves into a source skills directory" ;; esac

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

if $antigravity; then
  plugin_target="$destination/$plugin_name"
  plugin_stage="$stage/$plugin_name"
  mkdir -p -- "$plugin_stage/skills" "$plugin_stage/mcp"

  cp -- "$special_plugin_json" "$plugin_stage/plugin.json"
  cp -- "$special_mcp_script" "$plugin_stage/mcp/opencode_mcp.py"
  chmod +x "$plugin_stage/mcp/opencode_mcp.py"

  for source in "${sources[@]}"; do
    name="${source##*/}"
    mkdir -- "$plugin_stage/skills/$name"
    cp -R -- "$source/." "$plugin_stage/skills/$name/"
    if [[ -d "$special_dir/$name" ]]; then
      cp -R -- "$special_dir/$name/." "$plugin_stage/skills/$name/"
    fi
  done

  python_bin="$(command -v python3)"
  opencode_bin="$(command -v opencode || true)"
  if [[ -z "$opencode_bin" ]]; then
    for candidate in \
      "$HOME/.opencode/bin/opencode" \
      "$HOME/.local/bin/opencode" \
      "$HOME/.bun/bin/opencode" \
      "/opt/homebrew/bin/opencode" \
      "/usr/local/bin/opencode"; do
      if [[ -x "$candidate" ]]; then
        opencode_bin="$candidate"
        break
      fi
    done
  fi
  "$python_bin" - "$plugin_stage/mcp_config.json" "$python_bin" "$plugin_target/mcp/opencode_mcp.py" "$opencode_bin" <<'PY'
import json
import sys

out_path, python_bin, script_path, opencode_bin = sys.argv[1:5]
args = [script_path]
if opencode_bin:
    args.extend(["--opencode-bin", opencode_bin])
config = {
    "mcpServers": {
        "xz-agent-skills-opencode": {
            "command": python_bin,
            "args": args,
        }
    }
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY

  printf 'xz-agent-skills:plugin:%s\n' "$plugin_name" > "$plugin_stage/.xz-agent-skills-managed"

  resolved_proj_dirs=()
  resolved_links=()
  for proj_raw in ${project_raw_dirs[@]+"${project_raw_dirs[@]}"}; do
    [[ -d "$proj_raw" ]] || die "Project directory does not exist: $proj_raw"
    proj_dir="$(cd -- "$proj_raw" && pwd -P)"
    [[ "$proj_dir" != "/" ]] || die "Project directory cannot be '/': $proj_raw"
    plugins_link_dir="$proj_dir/.agents/plugins"
    mkdir -p -- "$plugins_link_dir"
    plugins_link_dir="$(cd -- "$plugins_link_dir" && pwd -P)"
    case "$plugins_link_dir/" in
      "$source_dir/"*|"$special_root/"*|"$destination/"*) die "Link directory must be outside source and installed plugins: $plugins_link_dir" ;;
    esac
    link="$plugins_link_dir/$plugin_name"
    if [[ -e "$link" && ! -L "$link" ]]; then
      die "Link conflict (not a symlink): $link"
    fi
    resolved_proj_dirs+=("$proj_dir")
    resolved_links+=("$plugins_link_dir")
  done

  if [[ -d "$plugin_target" && ! -L "$plugin_target" ]]; then
    for source in "${sources[@]}"; do
      name="${source##*/}"
      if [[ -d "$plugin_target/skills/$name" ]]; then
        if diff -qr -- "$plugin_stage/skills/$name" "$plugin_target/skills/$name" >/dev/null; then
          printf 'Unchanged skill: %s\n' "$name"
        else
          printf 'Updated skill: %s\n' "$name"
        fi
      else
        printf 'Installed skill: %s\n' "$name"
      fi
    done
    for old_skill in "$plugin_target/skills"/*/; do
      old_skill="${old_skill%/}"
      oname="${old_skill##*/}"
      [[ -d "$plugin_stage/skills/$oname" ]] || printf 'Removed skill: %s\n' "$oname"
    done
    if diff -qr -- "$plugin_stage" "$plugin_target" >/dev/null; then
      printf 'Unchanged: %s (plugin)\n' "$plugin_name"
    else
      mv -- "$plugin_target" "$stage/.previous/$plugin_name"
      if ! mv -- "$plugin_stage" "$plugin_target"; then
        mv -- "$stage/.previous/$plugin_name" "$plugin_target"
        die "Could not update plugin $plugin_name"
      fi
      printf 'Updated: %s (plugin)\n' "$plugin_name"
    fi
  elif [[ -e "$plugin_target" || -L "$plugin_target" ]]; then
    for source in "${sources[@]}"; do
      printf 'Installed skill: %s\n' "${source##*/}"
    done
    mv -- "$plugin_target" "$stage/.previous/$plugin_name"
    if ! mv -- "$plugin_stage" "$plugin_target"; then
      mv -- "$stage/.previous/$plugin_name" "$plugin_target"
      die "Could not replace plugin $plugin_name"
    fi
    printf 'Updated: %s (plugin)\n' "$plugin_name"
  else
    for source in "${sources[@]}"; do
      printf 'Installed skill: %s\n' "${source##*/}"
    done
    mv -- "$plugin_stage" "$plugin_target"
    printf 'Installed: %s (plugin)\n' "$plugin_name"
  fi

  for proj_dir in ${resolved_proj_dirs[@]+"${resolved_proj_dirs[@]}"}; do
    old_skills_dir="$proj_dir/.agents/skills"
    if [[ -d "$old_skills_dir" ]]; then
      for old_link in "$old_skills_dir"/*; do
        if is_managed_skill_symlink "$old_link"; then
          rm -- "$old_link"
          printf 'Unlinked: %s\n' "$old_link"
        fi
      done
      rmdir -- "$old_skills_dir" 2>/dev/null || true
    fi
  done

  for plugins_link_dir in ${resolved_links[@]+"${resolved_links[@]}"}; do
    link="$plugins_link_dir/$plugin_name"
    if [[ -L "$link" ]]; then
      if [[ "$(readlink -- "$link")" == "$plugin_target" ]]; then
        continue
      fi
      rm -- "$link"
      ln -s -- "$plugin_target" "$link"
      printf 'Relinked: %s\n' "$link"
    else
      ln -s -- "$plugin_target" "$link"
      printf 'Linked: %s\n' "$link"
    fi
  done
  printf 'Plugin available at %s\n' "$plugin_target"
  exit 0
fi

for source in "${sources[@]}"; do
  name="${source##*/}"
  mkdir -- "$stage/$name"
  cp -R -- "$source/." "$stage/$name/"
  printf 'xz-agent-skills:%s\n' "$name" > "$stage/$name/.xz-agent-skills-managed"
done

resolved_proj_dirs=()
resolved_links=()
for proj_raw in ${project_raw_dirs[@]+"${project_raw_dirs[@]}"}; do
  [[ -d "$proj_raw" ]] || die "Project directory does not exist: $proj_raw"
  proj_dir="$(cd -- "$proj_raw" && pwd -P)"
  [[ "$proj_dir" != "/" ]] || die "Project directory cannot be '/': $proj_raw"
  link_dir="$proj_dir/.agents/skills"
  mkdir -p -- "$link_dir"
  link_dir="$(cd -- "$link_dir" && pwd -P)"
  case "$link_dir/" in
    "$source_dir/"*|"$special_root/"*|"$destination/"*) die "Link directory must be outside source and installed skills: $link_dir" ;;
  esac
  for source in "${sources[@]}"; do
    name="${source##*/}"
    link="$link_dir/$name"
    if [[ -e "$link" && ! -L "$link" ]]; then
      die "Link conflict (not a symlink): $link"
    fi
  done
  resolved_proj_dirs+=("$proj_dir")
  resolved_links+=("$link_dir")
done

for source in "${sources[@]}"; do
  name="${source##*/}"
  target="$destination/$name"
  if [[ -d "$target" && ! -L "$target" ]]; then
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
  elif [[ -e "$target" || -L "$target" ]]; then
    mv -- "$target" "$stage/.previous/$name"
    if ! mv -- "$stage/$name" "$target"; then
      mv -- "$stage/.previous/$name" "$target"
      die "Could not replace $name"
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
  for link_dir in ${resolved_links[@]+"${resolved_links[@]}"}; do
    link="$link_dir/$name"
    if [[ -L "$link" && "$(readlink -- "$link")" == "$installed" ]]; then
      rm -- "$link"
      printf 'Unlinked: %s\n' "$link"
    fi
  done
done

for proj_dir in ${resolved_proj_dirs[@]+"${resolved_proj_dirs[@]}"}; do
  old_plugin_link="$proj_dir/.agents/plugins/$plugin_name"
  if is_managed_plugin_symlink "$old_plugin_link"; then
    rm -- "$old_plugin_link"
    printf 'Unlinked: %s\n' "$old_plugin_link"
    rmdir -- "$proj_dir/.agents/plugins" 2>/dev/null || true
  fi
done

for link_dir in ${resolved_links[@]+"${resolved_links[@]}"}; do
  for source in "${sources[@]}"; do
    name="${source##*/}"
    link="$link_dir/$name"
    if [[ -L "$link" ]]; then
      if [[ "$(readlink -- "$link")" == "$destination/$name" ]]; then
        continue
      fi
      rm -- "$link"
      ln -s -- "$destination/$name" "$link"
      printf 'Relinked: %s\n' "$link"
    else
      ln -s -- "$destination/$name" "$link"
      printf 'Linked: %s\n' "$link"
    fi
  done
done
printf 'Skills available at %s\n' "$destination"
