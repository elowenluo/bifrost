"""Check that every image publication in the release pipeline is gated per destination.

Release detection emits docker-publish-<destination>=true only for a tag the registry
confirmed absent. A push step that ignores its flag rebuilds over a published tag when a
partially failed release is retried, so every publication point must carry its own gate.
"""
from pathlib import Path
import unittest

import yaml


PIPELINE = Path(__file__).resolve().parent.parent / "release-pipeline.yml"
DESTINATIONS = ["version", "amd64", "arm64", "ubi9", "ubi9-amd64", "ubi9-arm64"]
# Manifest script -> the destination its versioned tag is.
MANIFEST_SCRIPTS = {
    "create-docker-manifest.sh": "version",
    "create-docker-manifest-ubi9.sh": "ubi9",
}


def gate(destination):
    return f"needs.detect-changes.outputs.docker-publish-{destination} == 'true'"


class DockerPublishWiringTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(PIPELINE.read_text())["jobs"]

    def test_detection_exposes_every_destination(self):
        outputs = self.jobs["detect-changes"]["outputs"]
        for destination in DESTINATIONS:
            name = f"docker-publish-{destination}"
            with self.subTest(output=name):
                self.assertEqual(outputs.get(name), f"${{{{ steps.detect.outputs.{name} }}}}")

    def test_every_publication_is_gated_on_its_own_destination(self):
        found = {}
        for job_name, job in self.jobs.items():
            for step in job.get("steps", []):
                uses = step.get("uses", "")
                run = step.get("run", "")
                label = f"{job_name}: {step.get('name', '?')}"
                pushes_image = "docker-build-push-action" in uses and step.get("with", {}).get("push")
                if pushes_image or "imagetools create" in run:
                    self.assertTrue(
                        job_name.startswith("docker-build-"),
                        f"{label} publishes an image outside a docker-build-* job",
                    )
                    destination = job_name[len("docker-build-"):]
                    self.assertIn(destination, DESTINATIONS, label)
                    self.assertEqual(step.get("if"), gate(destination), label)
                    found.setdefault(destination, []).append(label)
                for script, destination in MANIFEST_SCRIPTS.items():
                    if script in run:
                        self.assertEqual(
                            step.get("env", {}).get("PUBLISH_VERSION_TAG"),
                            f"${{{{ needs.detect-changes.outputs.docker-publish-{destination} }}}}",
                            label,
                        )
                        found.setdefault(destination, []).append(label)
                self.assertNotRegex(run, r"docker (manifest )?push", f"{label} pushes outside a gated path")
        # Each architecture job builds and mirrors; each manifest script runs once.
        for destination in DESTINATIONS:
            with self.subTest(destination=destination):
                expected = 1 if destination in MANIFEST_SCRIPTS.values() else 2
                self.assertEqual(len(found.get(destination, [])), expected, found.get(destination))


if __name__ == "__main__":
    unittest.main()
