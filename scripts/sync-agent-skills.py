#!/usr/bin/env python3
"""
sync-agent-skills.py

Bi-directional synchronization of agent skills across:
- Claude Code (~/.claude/skills)
- Antigravity / Gemini CLI (~/.gemini/config/skills)
- Cursor (~/.cursor/skills)
- Codex (~/.codex/skills)

Also imports skills from active Claude plugins:
- superpowers (14 skills)
- frontend-design
- skill-creator
"""

import os
import sys
import json
from pathlib import Path

HOME = Path.home()

# Agent target directories
TARGET_DIRS = {
    "claude": HOME / ".claude" / "skills",
    "gemini": HOME / ".gemini" / "config" / "skills",
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

def get_canonical_skills():
    """
    Harvests all skills that contain a SKILL.md.
    Returns dict: { skill_name: canonical_Path }
    """
    skills = {}

    # 1. Harvest from all agent personal directories
    for agent_name, agent_dir in TARGET_DIRS.items():
        if not agent_dir.exists():
            continue
        for entry in agent_dir.iterdir():
            if entry.name in IGNORED_NAMES or entry.name.startswith("."):
                continue
            # Resolve real path in case it's already a symlink
            try:
                real_path = entry.resolve()
                if (real_path / "SKILL.md").exists():
                    if entry.name not in skills:
                        skills[entry.name] = real_path
            except Exception:
                continue

    # 2. Harvest from Claude plugins (superpowers, frontend-design, skill-creator, etc.)
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
                                    if sub.name not in skills:
                                        skills[sub.name] = sub.resolve()
                        elif (install_path / "SKILL.md").exists():
                            plugin_name = plugin_key.split("@")[0]
                            if plugin_name not in skills:
                                skills[plugin_name] = install_path.resolve()
        except Exception as e:
            print(f"Warning reading installed plugins: {e}", file=sys.stderr)

    return skills

def sync():
    skills = get_canonical_skills()
    print(f"Discovered {len(skills)} canonical skills:")
    for name, path in sorted(skills.items()):
        print(f"  - {name} -> {path}")

    # Ensure all target directories exist
    for agent, target_dir in TARGET_DIRS.items():
        target_dir.mkdir(parents=True, exist_ok=True)

    links_created = 0
    links_existing = 0
    skipped_real = 0

    for agent, target_dir in TARGET_DIRS.items():
        for skill_name, canonical_path in sorted(skills.items()):
            dest = target_dir / skill_name

            # Check if broken symlink
            if dest.is_symlink() and not dest.exists():
                try:
                    dest.unlink()
                except Exception:
                    pass

            # Case 1: dest does not exist at all
            if not dest.exists() and not dest.is_symlink():
                try:
                    dest.symlink_to(canonical_path)
                    print(f"[{agent}] Created symlink: {skill_name} -> {canonical_path}")
                    links_created += 1
                except Exception as e:
                    print(f"[{agent}] Failed to link {skill_name}: {e}", file=sys.stderr)
            elif dest.is_symlink():
                # Verify destination
                try:
                    current_target = dest.resolve()
                    if current_target == canonical_path:
                        links_existing += 1
                    else:
                        # Point to canonical
                        dest.unlink()
                        dest.symlink_to(canonical_path)
                        print(f"[{agent}] Updated symlink: {skill_name} -> {canonical_path}")
                        links_created += 1
                except Exception as e:
                    print(f"[{agent}] Failed to check/update {skill_name}: {e}", file=sys.stderr)
            else:
                # Real directory already exists
                skipped_real += 1

    print(f"\nSync complete. Created/updated {links_created} symlinks. {links_existing} already up to date. {skipped_real} real directories preserved.")

if __name__ == "__main__":
    sync()
