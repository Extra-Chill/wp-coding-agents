#!/usr/bin/env python3
"""Regression coverage for the managed Roadie bridge prompt composition."""
from pathlib import Path
import unittest

import yaml


class ManagedBridgePromptTest(unittest.TestCase):
    def test_parallel_work_guidance_reaches_composed_bridge_context(self):
        path = Path(__file__).resolve().parents[1] / "bridges/roadie/prompt-config.yaml"
        config = yaml.safe_load(path.read_text())
        managed = [section for section in config["append"] if section["id"] == "managed-bridge"]
        self.assertEqual(len(managed), 1)
        self.assertNotIn("managed-bridge", config["disable"])

        # Roadie's prompt contract appends these content blocks to its context.
        context = "\n\n".join(section["content"] for section in config["append"])
        instruction = (
            "**Parallel scoped work:** delegate it to your runtime's subagent tool. "
            "Subagents run as child sessions in this thread and return their results to you. "
            "Use `roadie send` only to post to or start *other* threads."
        )
        self.assertIn(instruction, managed[0]["content"])
        self.assertIn(instruction, context)


if __name__ == "__main__":
    unittest.main()
