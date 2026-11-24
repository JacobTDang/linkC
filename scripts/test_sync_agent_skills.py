#!/usr/bin/env python3
"""
test_sync_agent_skills.py

Unit tests for sync-agent-skills.py.
Tests that new target directories (opencode, crush, kilo) and the repo skills/
source are properly supported, symlinks are created, and real directories
are never overwritten.
"""

import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import importlib.util

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "sync-agent-skills.py"

def load_sync_module():
    spec = importlib.util.spec_from_file_location("sync_agent_skills", SCRIPT_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

class TestSyncAgentSkills(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.fake_home = Path(self.temp_dir.name) / "home"
        self.fake_home.mkdir(parents=True)
        self.mod = load_sync_module()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_target_dirs_include_new_agents(self):
        """TARGET_DIRS must include opencode, crush, and kilo with correct paths."""
        self.assertIn("opencode", self.mod.TARGET_DIRS)
        self.assertIn("crush", self.mod.TARGET_DIRS)
        self.assertIn("kilo", self.mod.TARGET_DIRS)

        # Check expected paths relative to HOME
        self.assertEqual(
            self.mod.TARGET_DIRS["opencode"].relative_to(self.mod.HOME),
            Path(".config/opencode/skills")
        )
        self.assertEqual(
            self.mod.TARGET_DIRS["crush"].relative_to(self.mod.HOME),
            Path(".config/crush/skills")
        )
        self.assertEqual(
            self.mod.TARGET_DIRS["kilo"].relative_to(self.mod.HOME),
            Path(".config/kilo/skills")
        )

    def test_repo_skills_included_in_canonical_skills(self):
        """Repo skills/ folder must be included as a canonical skill source."""
        with tempfile.TemporaryDirectory() as repo_temp:
            fake_repo = Path(repo_temp)
            skills_dir = fake_repo / "skills" / "browse-efficiently"
            skills_dir.mkdir(parents=True)
            skill_md = skills_dir / "SKILL.md"
            skill_md.write_text("---\nname: browse-efficiently\n---\n# Browse")

            with patch.object(self.mod, "REPO_SKILLS_DIR", fake_repo / "skills"):
                canonical = self.mod.get_canonical_skills()
                self.assertIn("browse-efficiently", canonical)
                self.assertEqual(canonical["browse-efficiently"], skills_dir.resolve())

    def test_sync_creates_symlinks_and_preserves_real_dirs(self):
        """Sync must create symlinks in target dirs and never clobber real dirs."""
        fake_home = self.fake_home
        # Create a mock source skill in repo skills dir
        repo_skills = fake_home / "repo_skills"
        browse_skill = repo_skills / "browse-efficiently"
        browse_skill.mkdir(parents=True)
        (browse_skill / "SKILL.md").write_text("---\nname: browse-efficiently\n---\n# Content")

        # Mock targets under fake_home
        mock_targets = {
            "claude": fake_home / ".claude" / "skills",
            "opencode": fake_home / ".config" / "opencode" / "skills",
            "crush": fake_home / ".config" / "crush" / "skills",
            "kilo": fake_home / ".config" / "kilo" / "skills",
        }

        # Put a REAL directory in crush target for browse-efficiently to test protection
        crush_real = mock_targets["crush"] / "browse-efficiently"
        crush_real.mkdir(parents=True)
        (crush_real / "SKILL.md").write_text("---\nname: real-crush\n---\n# Real")

        with patch.object(self.mod, "HOME", fake_home), \
             patch.object(self.mod, "TARGET_DIRS", mock_targets), \
             patch.object(self.mod, "REPO_SKILLS_DIR", repo_skills):

            self.mod.sync()

            # opencode and kilo should have symlinks
            opencode_dest = mock_targets["opencode"] / "browse-efficiently"
            self.assertTrue(opencode_dest.is_symlink())
            self.assertEqual(opencode_dest.resolve(), browse_skill.resolve())

            kilo_dest = mock_targets["kilo"] / "browse-efficiently"
            self.assertTrue(kilo_dest.is_symlink())
            self.assertEqual(kilo_dest.resolve(), browse_skill.resolve())

            # crush should still be a real directory, NOT a symlink
            self.assertFalse(crush_real.is_symlink())
            self.assertTrue(crush_real.is_dir())
            self.assertEqual((crush_real / "SKILL.md").read_text(), "---\nname: real-crush\n---\n# Real")

if __name__ == "__main__":
    unittest.main()
