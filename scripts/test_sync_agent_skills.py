#!/usr/bin/env python3
"""
test_sync_agent_skills.py

Unit tests for sync-agent-skills.py.

Run with:
    python3 -m unittest discover -s scripts
"""

import io
import os
import shutil
import subprocess
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
        self.mock_repo = Path(self.temp_dir.name) / "repo"
        self.mock_repo_skills = self.mock_repo / "skills"
        self.mock_repo_skills.mkdir(parents=True)

        self.mock_targets = {
            "claude": self.fake_home / ".claude" / "skills",
            "agy": self.fake_home / ".gemini" / "config" / "skills",
            "cursor": self.fake_home / ".cursor" / "skills",
            "codex": self.fake_home / ".codex" / "skills",
        }
        for d in self.mock_targets.values():
            d.mkdir(parents=True)

        self.mod = load_sync_module()

        self.patcher_home = patch.object(self.mod, "HOME", self.fake_home)
        self.patcher_targets = patch.object(self.mod, "TARGET_DIRS", self.mock_targets)
        self.patcher_repo_skills = patch.object(self.mod, "REPO_SKILLS_DIR", self.mock_repo_skills)
        self.patcher_repo_root = patch.object(self.mod, "REPO_ROOT", self.mock_repo)

        self.patcher_home.start()
        self.patcher_targets.start()
        self.patcher_repo_skills.start()
        self.patcher_repo_root.start()

    def tearDown(self):
        self.patcher_repo_root.stop()
        self.patcher_repo_skills.stop()
        self.patcher_targets.stop()
        self.patcher_home.stop()
        self.temp_dir.cleanup()

    def test_target_dirs_do_not_include_opencode_crush_kilo(self):
        """OpenCode, Crush, and Kilo must not be in TARGET_DIRS (they read ~/.claude/skills and ~/.agents/skills)."""
        # Inspect raw module definition by reloading without mock
        raw_mod = load_sync_module()
        self.assertNotIn("opencode", raw_mod.TARGET_DIRS)
        self.assertNotIn("crush", raw_mod.TARGET_DIRS)
        self.assertNotIn("kilo", raw_mod.TARGET_DIRS)
        self.assertIn("claude", raw_mod.TARGET_DIRS)
        self.assertIn("agy", raw_mod.TARGET_DIRS)
        self.assertIn("cursor", raw_mod.TARGET_DIRS)
        self.assertIn("codex", raw_mod.TARGET_DIRS)

    def test_repo_skills_included_in_canonical_skills(self):
        """Repo skills/ folder must be included as a canonical skill source in hermetic environment."""
        skills_dir = self.mock_repo_skills / "browse-efficiently"
        skills_dir.mkdir(parents=True)
        skill_md = skills_dir / "SKILL.md"
        skill_md.write_text("---\nname: browse-efficiently\n---\n# Browse")

        canonical = self.mod.get_canonical_skills()
        self.assertIn("browse-efficiently", canonical)
        self.assertEqual(canonical["browse-efficiently"], skills_dir.resolve())

    def test_sync_creates_symlinks_and_preserves_real_dirs(self):
        """Sync must create symlinks in target dirs and preserve real directories."""
        browse_skill = self.mock_repo_skills / "browse-efficiently"
        browse_skill.mkdir(parents=True)
        (browse_skill / "SKILL.md").write_text("---\nname: browse-efficiently\n---\n# Content")

        # Put a REAL directory in cursor target for browse-efficiently
        cursor_real = self.mock_targets["cursor"] / "browse-efficiently"
        cursor_real.mkdir(parents=True)
        (cursor_real / "SKILL.md").write_text("---\nname: real-cursor\n---\n# Real")

        self.mod.sync()

        # claude should have a symlink
        claude_dest = self.mock_targets["claude"] / "browse-efficiently"
        self.assertTrue(claude_dest.is_symlink())
        self.assertEqual(claude_dest.resolve(), browse_skill.resolve())

        # cursor should still be a real directory, NOT a symlink
        self.assertFalse(cursor_real.is_symlink())
        self.assertTrue(cursor_real.is_dir())
        self.assertEqual((cursor_real / "SKILL.md").read_text(), "---\nname: real-cursor\n---\n# Real")

    def test_stale_symlink_repointed(self):
        """A symlink pointing to an old path in a known source must be repointed to canonical path."""
        # Canonical skill in repo
        canonical_dir = self.mock_repo_skills / "test-skill"
        canonical_dir.mkdir(parents=True)
        (canonical_dir / "SKILL.md").write_text("# Test Skill Canonical")

        # Old path in known source (e.g. inside mock_repo)
        old_source = self.mock_repo / "old_worktree" / "skills" / "test-skill"
        old_source.mkdir(parents=True)
        (old_source / "SKILL.md").write_text("# Test Skill Old")

        # claude has a symlink pointing to the old known source
        dest = self.mock_targets["claude"] / "test-skill"
        dest.symlink_to(old_source)
        self.assertEqual(dest.resolve(), old_source.resolve())

        self.mod.sync()

        # Must be repointed to canonical_dir
        self.assertTrue(dest.is_symlink())
        self.assertEqual(dest.resolve(), canonical_dir.resolve())

    def test_broken_symlink_cleanup(self):
        """A broken symlink in a target directory must be cleaned up and relinked to canonical path."""
        canonical_dir = self.mock_repo_skills / "broken-target-skill"
        canonical_dir.mkdir(parents=True)
        (canonical_dir / "SKILL.md").write_text("# Canonical")

        # Create broken symlink in agy target
        dest = self.mock_targets["agy"] / "broken-target-skill"
        dest.symlink_to(self.fake_home / "nonexistent_path_xyz")
        self.assertTrue(dest.is_symlink())
        self.assertFalse(dest.exists())

        self.mod.sync()

        # Must now exist and point to canonical_dir
        self.assertTrue(dest.is_symlink())
        self.assertTrue(dest.exists())
        self.assertEqual(dest.resolve(), canonical_dir.resolve())

    def test_link_error_exits_nonzero(self):
        """A failure during symlink creation must print errors and exit with non-zero status."""
        canonical_dir = self.mock_repo_skills / "err-skill"
        canonical_dir.mkdir(parents=True)
        (canonical_dir / "SKILL.md").write_text("# Canonical")

        # Mock symlink_to to raise an error
        orig_symlink_to = Path.symlink_to

        def mock_symlink_fail(path_self, target, target_is_directory=False):
            if path_self.name == "err-skill":
                raise PermissionError("Permission denied simulating link failure")
            return orig_symlink_to(path_self, target, target_is_directory)

        with patch.object(Path, "symlink_to", autospec=True, side_effect=mock_symlink_fail), \
             patch("sys.stderr", new_callable=io.StringIO) as mock_stderr:
            with self.assertRaises(SystemExit) as cm:
                self.mod.sync()
            self.assertEqual(cm.exception.code, 1)
            self.assertIn("Failed to link err-skill", mock_stderr.getvalue())
            self.assertIn("Permission denied simulating link failure", mock_stderr.getvalue())

    def test_no_repointing_of_user_valid_link(self):
        """A valid user symlink pointing outside known sources must NOT be repointed to canonical."""
        # Canonical skill in repo
        canonical_dir = self.mock_repo_skills / "user-custom-skill"
        canonical_dir.mkdir(parents=True)
        (canonical_dir / "SKILL.md").write_text("# Canonical in repo")

        # User's own valid directory outside known sources
        user_own_dir = self.fake_home / "my_custom_projects" / "user-custom-skill"
        user_own_dir.mkdir(parents=True)
        (user_own_dir / "SKILL.md").write_text("# User's own copy")

        # User's symlink in claude
        dest = self.mock_targets["claude"] / "user-custom-skill"
        dest.symlink_to(user_own_dir)

        self.mod.sync()

        # Link must remain pointing to user's own copy, NOT repointed to repo
        self.assertTrue(dest.is_symlink())
        self.assertEqual(dest.resolve(), user_own_dir.resolve())

    def test_duplicate_name_warning(self):
        """Finding the same skill name in more than one source with different paths must warn to stderr."""
        # Skill in repo
        repo_skill = self.mock_repo_skills / "dup-skill"
        repo_skill.mkdir(parents=True)
        (repo_skill / "SKILL.md").write_text("# Repo")

        # Another skill with same name in claude target
        claude_skill = self.mock_targets["claude"] / "dup-skill"
        claude_skill.mkdir(parents=True)
        (claude_skill / "SKILL.md").write_text("# Claude personal")

        with patch("sys.stderr", new_callable=io.StringIO) as mock_stderr:
            skills = self.mod.get_canonical_skills()
            stderr_val = mock_stderr.getvalue()
            self.assertIn("Warning: conflicting source for skill 'dup-skill'", stderr_val)
            self.assertIn("won", stderr_val)
            self.assertIn("dup-skill", skills)

    def test_resolve_repo_root_in_worktree(self):
        """resolve_repo_root must return the main checkout root when executed from a worktree.

        Note: Needs git 2.31 or newer for --path-format.
        """
        git_env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null"}
        git_cmd = [
            "git",
            "-c", "commit.gpgsign=false",
            "-c", "user.name=Test User",
            "-c", "user.email=test@example.com",
        ]
        with tempfile.TemporaryDirectory() as td:
            main_repo = Path(td) / "main_repo"
            main_repo.mkdir()
            subprocess.run([*git_cmd, "init", "-b", "main"], cwd=main_repo, check=True, capture_output=True, env=git_env)
            (main_repo / "README.md").write_text("# Main")
            subprocess.run([*git_cmd, "add", "."], cwd=main_repo, check=True, env=git_env)
            subprocess.run([*git_cmd, "commit", "-m", "init"], cwd=main_repo, check=True, capture_output=True, env=git_env)

            wt = Path(td) / "wt"
            subprocess.run([*git_cmd, "worktree", "add", "-b", "feat", str(wt)], cwd=main_repo, check=True, capture_output=True, env=git_env)
            wt_scripts = wt / "scripts"
            wt_scripts.mkdir(parents=True)

            resolved = self.mod.resolve_repo_root(from_dir=wt_scripts)
            self.assertEqual(resolved, main_repo.resolve())

    def test_resolve_repo_root_from_scripts_different_cwd(self):
        """resolve_repo_root(from_dir=main_repo/'scripts') must return main checkout root from a different cwd.

        Without --path-format=absolute, git returns '../.git' which resolves relative to the caller's cwd.
        Note: Needs git 2.31 or newer for --path-format.
        """
        git_env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null"}
        git_cmd = [
            "git",
            "-c", "commit.gpgsign=false",
            "-c", "user.name=Test User",
            "-c", "user.email=test@example.com",
        ]
        with tempfile.TemporaryDirectory() as td:
            main_repo = Path(td) / "main_repo"
            main_repo.mkdir()
            subprocess.run([*git_cmd, "init", "-b", "main"], cwd=main_repo, check=True, capture_output=True, env=git_env)
            (main_repo / "README.md").write_text("# Main")
            subprocess.run([*git_cmd, "add", "."], cwd=main_repo, check=True, env=git_env)
            subprocess.run([*git_cmd, "commit", "-m", "init"], cwd=main_repo, check=True, capture_output=True, env=git_env)

            scripts = main_repo / "scripts"
            scripts.mkdir(parents=True)

            other_dir = Path(td) / "other_cwd"
            other_dir.mkdir()
            orig_cwd = os.getcwd()
            try:
                os.chdir(other_dir)
                resolved = self.mod.resolve_repo_root(from_dir=scripts)
                self.assertEqual(resolved, main_repo.resolve())
            finally:
                os.chdir(orig_cwd)

    def test_resolve_repo_root_failure_includes_stderr(self):
        """resolve_repo_root error message must include git stderr when rev-parse fails."""
        with tempfile.TemporaryDirectory() as td:
            non_git_dir = Path(td) / "not_a_git_repo"
            non_git_dir.mkdir()
            with patch("sys.stderr", new_callable=io.StringIO) as mock_stderr:
                with self.assertRaises(SystemExit) as cm:
                    self.mod.resolve_repo_root(from_dir=non_git_dir)
                self.assertEqual(cm.exception.code, 1)
                stderr_val = mock_stderr.getvalue()
                self.assertIn("failed to resolve main git checkout root", stderr_val)
                self.assertIn("not a git repository", stderr_val)

    def test_import_hermetic_without_git(self):
        """Importing sync-agent-skills must be hermetic and succeed even when git rev-parse fails."""
        with patch("subprocess.check_output", side_effect=subprocess.CalledProcessError(128, ["git", "rev-parse"])):
            mod = load_sync_module()
            self.assertIsNotNone(mod)

if __name__ == "__main__":
    unittest.main()
