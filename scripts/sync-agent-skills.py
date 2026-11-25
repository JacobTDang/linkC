#!/usr/bin/env python3
"""
sync-agent-skills.py

Bi-directional synchronization of agent skills across:
- Claude Code (~/.claude/skills)
- Antigravity CLI (~/.gemini/config/skills)
- Cursor (~/.cursor/skills)
- Codex (~/.codex/skills)

Also imports skills from:
- linkC repository skills/ directory
- Active Claude plugins (superpowers, frontend-design, skill-creator, etc.)
"""

import os
import sys
import json
import subprocess
from pathlib import Path

HOME = Path.home()

def resolve_repo_root(from_dir: Path | None = None) -> Path:
    """
    Resolves the repo root as the MAIN checkout via git rev-parse --path-format=absolute --git-common-dir,
    then its parent. Fails loudly if git cannot determine it.
    """
    cwd = from_dir if from_dir is not None else Path(__file__).resolve().parent
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=cwd,
            stderr=subprocess.PIPE,
            text=True,
        ).strip()
        common_dir = Path(out)
        return common_dir.parent.resolve()
    except Exception as e:
        print(f"Error: failed to resolve main git checkout root: {e}", file=sys.stderr)
        sys.exit(1)

REPO_ROOT = None
REPO_SKILLS_DIR = None

def init_repo_root(from_dir: Path | None = None):
    global REPO_ROOT, REPO_SKILLS_DIR
    if REPO_ROOT is None:
        REPO_ROOT = resolve_repo_root(from_dir=from_dir)
    if REPO_SKILLS_DIR is None:
        REPO_SKILLS_DIR = REPO_ROOT / "skills"

# OpenCode, Crush, and Kilo already read ~/.claude/skills and ~/.agents/skills, so targeting them caused duplicate skills.
TARGET_DIRS = {
    "claude": HOME / ".claude" / "skills",
    "agy": HOME / ".gemini" / "config" / "skills",
    "cursor": HOME / ".cursor" / "skills",
    "codex": HOME / ".codex" / "skills",
}

# Ignored directory names or prefixes
IGNORED_NAMES = {
    ".system",
    ".git",
    ".DS_Store",
    ".sync-manifest.json",
    "deep-research-workspace",  # benchmark/eval workspace without top-level SKILL.md
}

def is_known_source(path: Path) -> bool:
    """
    Returns True if path points into a recognized skill source directory
    (the repo root / skills dir, an agent target directory, or Claude plugins).
    """
    try:
        resolved = path.resolve()
    except Exception:
        return False

    # Check REPO_SKILLS_DIR and REPO_ROOT
    try:
        if REPO_SKILLS_DIR and resolved.is_relative_to(REPO_SKILLS_DIR.resolve()):
            return True
        if REPO_ROOT and resolved.is_relative_to(REPO_ROOT.resolve()):
            return True
    except (ValueError, Exception):
        pass

    # Check agent target directories
    for target_dir in TARGET_DIRS.values():
        try:
            if resolved.is_relative_to(target_dir.resolve()):
                return True
        except (ValueError, Exception):
            pass

    # Check Claude plugins
    plugins_dir = HOME / ".claude" / "plugins"
    try:
        if resolved.is_relative_to(plugins_dir.resolve()):
            return True
    except (ValueError, Exception):
        pass

    return False

def get_canonical_skills(errors=None):
    """
    Harvests all skills that contain a SKILL.md.
    Returns dict: { skill_name: canonical_Path }
    """
    init_repo_root()
    skills = {}

    def record_skill(name, real_path, source_desc):
        if name not in skills:
            skills[name] = real_path
        elif skills[name] != real_path:
            print(f"Warning: conflicting source for skill '{name}': keeping {skills[name]} (won), ignoring {real_path} ({source_desc})", file=sys.stderr)

    # 1. Harvest from repo skills/ folder if present
    if REPO_SKILLS_DIR and REPO_SKILLS_DIR.exists():
        for entry in REPO_SKILLS_DIR.iterdir():
            if entry.name in IGNORED_NAMES or entry.name.startswith("."):
                continue
            try:
                real_path = entry.resolve()
                if (real_path / "SKILL.md").exists():
                    record_skill(entry.name, real_path, "repo skills")
            except Exception as e:
                msg = f"Failed to inspect repo skill entry '{entry}': {e}"
                print(msg, file=sys.stderr)
                if errors is not None:
                    errors.append(msg)

    # 2. Harvest from all agent personal directories
    for agent_name, agent_dir in TARGET_DIRS.items():
        if not agent_dir.exists():
            continue
        for entry in agent_dir.iterdir():
            if entry.name in IGNORED_NAMES or entry.name.startswith("."):
                continue
            try:
                real_path = entry.resolve()
                if (real_path / "SKILL.md").exists():
                    record_skill(entry.name, real_path, f"agent {agent_name}")
            except Exception as e:
                msg = f"Failed to inspect agent skill entry '{entry}' in {agent_dir}: {e}"
                print(msg, file=sys.stderr)
                if errors is not None:
                    errors.append(msg)

    # 3. Harvest from Claude plugins (superpowers, frontend-design, skill-creator, etc.)
    plugins_installed_file = HOME / ".claude" / "plugins" / "installed_plugins.json"
    if plugins_installed_file.exists():
        try:
            with open(plugins_installed_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                for plugin_key, installs in data.get("plugins", {}).items():
                    for inst in installs:
                        install_path = Path(inst.get("installPath", ""))
                        if not install_path.exists():
                            continue
                        # Look for skills directory or direct SKILL.md
                        skills_dir = install_path / "skills"
                        if skills_dir.exists():
                            for sub in skills_dir.iterdir():
                                if sub.is_dir() and (sub / "SKILL.md").exists():
                                    record_skill(sub.name, sub.resolve(), f"plugin {plugin_key}")
                        elif (install_path / "SKILL.md").exists():
                            plugin_name = plugin_key.split("@")[0]
                            record_skill(plugin_name, install_path.resolve(), f"plugin {plugin_key}")
        except Exception as e:
            msg = f"Warning reading installed plugins: {e}"
            print(msg, file=sys.stderr)
            if errors is not None:
                errors.append(msg)

    return skills

def sync():
    errors = []
    skills = get_canonical_skills(errors=errors)
    print(f"Discovered {len(skills)} canonical skills:")
    for name, path in sorted(skills.items()):
        print(f"  - {name} -> {path}")

    # Ensure all target directories exist
    for agent, target_dir in TARGET_DIRS.items():
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            msg = f"Failed to create target directory {target_dir}: {e}"
            print(msg, file=sys.stderr)
            errors.append(msg)

    links_created = 0
    links_existing = 0
    skipped_dirs = 0
    skipped_files = 0

    for agent, target_dir in TARGET_DIRS.items():
        for skill_name, canonical_path in sorted(skills.items()):
            dest = target_dir / skill_name

            # Check if broken symlink
            if dest.is_symlink() and not dest.exists():
                try:
                    dest.unlink()
                except Exception as e:
                    msg = f"[{agent}] Failed to remove broken symlink {dest}: {e}"
                    print(msg, file=sys.stderr)
                    errors.append(msg)
                    continue

            # Case 1: dest does not exist at all
            if not dest.exists() and not dest.is_symlink():
                try:
                    dest.symlink_to(canonical_path)
                    print(f"[{agent}] Created symlink: {skill_name} -> {canonical_path}")
                    links_created += 1
                except Exception as e:
                    msg = f"[{agent}] Failed to link {skill_name}: {e}"
                    print(msg, file=sys.stderr)
                    errors.append(msg)
            elif dest.is_symlink():
                # Destination is an existing symlink
                try:
                    current_target = dest.resolve()
                    if current_target == canonical_path:
                        links_existing += 1
                    elif is_known_source(current_target):
                        # Stale symlink pointing into a known source: repoint to canonical
                        dest.unlink()
                        dest.symlink_to(canonical_path)
                        print(f"[{agent}] Updated symlink: {skill_name} -> {canonical_path}")
                        links_created += 1
                    else:
                        # User's own valid link outside known sources: preserve it
                        print(f"[{agent}] Preserved user's own symlink: {skill_name} -> {current_target}")
                except Exception as e:
                    msg = f"[{agent}] Failed to check/update {skill_name}: {e}"
                    print(msg, file=sys.stderr)
                    errors.append(msg)
            else:
                # Real directory or file already exists
                if dest.is_dir():
                    skipped_dirs += 1
                else:
                    skipped_files += 1

    if errors:
        print(f"\nEncountered {len(errors)} error(s) during sync.", file=sys.stderr)
        sys.exit(1)

    print(f"\nSync complete. Created/updated {links_created} symlinks. {links_existing} already up to date. {skipped_dirs} real directories and {skipped_files} real files preserved.")

def main():
    init_repo_root()
    sync()

if __name__ == "__main__":
    main()
