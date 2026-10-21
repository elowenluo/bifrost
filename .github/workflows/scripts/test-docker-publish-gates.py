"""Check that no release image publication can overwrite a published tag, on any attempt.

Release detection runs once per workflow run, but GitHub re-runs a failed job with the
outputs detection wrote the first time. So every job that publishes an image asks the
registry for its own tag right before pushing (ghcr-tag-gate.sh), on every attempt, and
gates its pushes on that answer alone.

The structural tests pin that wiring in release-pipeline.yml. The replay tests execute each
publishing job's real gate and manifest steps, rendered from the workflow, against a fake
registry (testdata/fake-ghcr-curl) and a fake docker (testdata/fake-docker), with detection's
outputs held at their original "publish" values while the registry changes between attempts.
Nothing reaches a registry.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml


SCRIPTS = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS.parents[2]
PIPELINE = SCRIPTS.parent / "release-pipeline.yml"

# Publishing job -> the tag suffix it publishes.
PUBLISHERS = {
    "docker-build-amd64": "-amd64",
    "docker-build-arm64": "-arm64",
    "docker-build-ubi9-amd64": "-ubi9-amd64",
    "docker-build-ubi9-arm64": "-ubi9-arm64",
    "docker-manifest": "",
    "docker-manifest-ubi9": "-ubi9",
}
MANIFEST_SCRIPTS = ("create-docker-manifest.sh", "create-docker-manifest-ubi9.sh")
GATE = "steps.recheck.outputs.publish == 'true'"

VERSION = "2.3.2"
JOB_TOKEN = "ghs_SENTINELjobtoken0123456789"
BEARER = "SENTINELbearer456+/="
TOKEN_OK = f'200 0 {{"token":"{BEARER}"}}'
MANIFEST_OK = '200 0 {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}'
MANIFEST_UNKNOWN = '404 0 {"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}'
TAGS_OK = '200 0 {"name":"txehq/bifrost","tags":[]}'

EXPRESSION = re.compile(r"\$\{\{\s*(.+?)\s*\}\}")
CONDITION = re.compile(r"^([A-Za-z0-9_.-]+) == 'true'$")


def load_jobs():
    return yaml.safe_load(PIPELINE.read_text())["jobs"]


def publishes(step):
    """What kind of publication a step performs, if any."""
    uses = step.get("uses", "")
    run = step.get("run", "")
    if "docker-build-push-action" in uses and step.get("with", {}).get("push"):
        return "build"
    if "imagetools create" in run:
        return "mirror"
    if any(script in run for script in MANIFEST_SCRIPTS):
        return "manifest"
    return None


class StructureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = load_jobs()

    def test_every_publication_is_gated_on_a_fresh_registry_answer(self):
        seen = {job: [] for job in PUBLISHERS}
        for job_name, job in self.jobs.items():
            recheck_seen = False
            for step in job.get("steps", []):
                label = f"{job_name}: {step.get('name', '?')}"
                text = yaml.safe_dump(step)
                self.assertNotIn("docker-publish-", text, f"{label} still reads a detection-time flag")
                if step.get("id") == "recheck":
                    self.assertIn(job_name, PUBLISHERS, f"{label}: re-check outside a publishing job")
                    self.assertIn("ghcr-tag-gate.sh", step.get("run", ""), label)
                    self.assertNotIn("if", step, f"{label} must run on every attempt")
                    recheck_seen = True
                kind = publishes(step)
                self.assertNotRegex(step.get("run", ""), r"docker (manifest )?push", f"{label} pushes outside a gated path")
                if kind is None:
                    continue
                self.assertIn(job_name, PUBLISHERS, f"{label} publishes outside a known publishing job")
                self.assertTrue(recheck_seen, f"{label} publishes before re-checking the registry")
                if kind == "manifest":
                    self.assertEqual(step.get("env", {}).get("PUBLISH_VERSION_TAG"), "${{ steps.recheck.outputs.publish }}", label)
                    self.assertNotIn("if", step, label)
                else:
                    self.assertEqual(step.get("if"), GATE, label)
                seen[job_name].append(kind)
        self.assertEqual(
            seen,
            {
                job: (["manifest"] if job.startswith("docker-manifest") else ["build", "mirror"])
                for job in PUBLISHERS
            },
        )


class ReplayTest(unittest.TestCase):
    """Run publishing jobs' gate and manifest steps as GitHub would on each attempt."""

    @classmethod
    def setUpClass(cls):
        cls.jobs = load_jobs()
        cls.work = Path(tempfile.mkdtemp())
        cls.bin = cls.work / "bin"
        cls.bin.mkdir()
        shutil.copy(SCRIPTS / "testdata" / "fake-ghcr-curl", cls.bin / "curl")
        shutil.copy(SCRIPTS / "testdata" / "fake-docker", cls.bin / "docker")
        (cls.bin / "sleep").write_text("#!/usr/bin/env bash\nexit 0\n")
        for tool in ("curl", "docker", "sleep"):
            (cls.bin / tool).chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work)

    def attempt(self, job_name, present, registry_error=None, fail_push=None, token=TOKEN_OK):
        """One attempt of a publishing job. `present` is the set of tags the registry holds.

        Detection's outputs stay at what a first, all-absent run wrote, as a re-run of a
        failed job sees them. Returns (tags pushed, whether the attempt failed).
        """
        job = self.jobs[job_name]
        fake = Path(tempfile.mkdtemp(dir=self.work))
        for name in ("calls.log", "argv.log", "stdin.log"):
            (fake / name).touch()
        (fake / "token").write_text(token + "\n")
        (fake / "manifest").write_text((registry_error or MANIFEST_UNKNOWN) + "\n")
        for tag in present:
            (fake / f"manifest:{tag}").write_text(MANIFEST_OK + "\n")
        (fake / "tags").write_text(TAGS_OK + "\n")
        docker_log = fake / "docker.log"
        docker_log.touch()

        context = {
            "github.repository_owner": "txehq",
            "github.actor": "release-bot",
            "github.token": JOB_TOKEN,
            "secrets.GITHUB_TOKEN": JOB_TOKEN,
            "needs.detect-changes.outputs.transport-version": VERSION,
            "needs.detect-changes.outputs.docker-needs-release": "true",
        }
        # What a first, all-absent detection would have written for per-destination flags,
        # so a pipeline that gates on them is replayed with the stale answer a re-run sees.
        for name in ("version", "amd64", "arm64", "ubi9", "ubi9-amd64", "ubi9-arm64"):
            context[f"needs.detect-changes.outputs.docker-publish-{name}"] = "true"

        def render(value):
            return EXPRESSION.sub(lambda m: context[m.group(1)], str(value))

        job_env = {key: render(value) for key, value in job.get("env", {}).items()}
        pushed = []
        for step in job["steps"]:
            condition = step.get("if")
            if condition is not None:
                match = CONDITION.match(condition)
                self.assertIsNotNone(match, f"{job_name}: unsupported condition {condition!r}")
                if context.get(match.group(1)) != "true":
                    continue
            kind = publishes(step)
            if step.get("id") == "recheck" or kind == "manifest":
                output = fake / "github_output"
                output.write_text("")
                env = dict(os.environ)
                env.pop("GITHUB_TOKEN", None)
                env.update(job_env)
                env.update({key: render(value) for key, value in step.get("env", {}).items()})
                env.update(
                    PATH=f"{self.bin}:{os.environ['PATH']}",
                    FAKE_DIR=str(fake),
                    DOCKER_LOG=str(docker_log),
                    GITHUB_OUTPUT=str(output),
                )
                if fail_push:
                    env["FAKE_DOCKER_FAIL_PUSH"] = fail_push
                result = subprocess.run(
                    ["bash", "-e", "-c", render(step["run"])],
                    cwd=REPO_ROOT, env=env, capture_output=True, text=True,
                )
                for log in (result.stdout + result.stderr, (fake / "argv.log").read_text()):
                    self.assertNotIn(JOB_TOKEN, log, f"{job_name}: job token leaked")
                    self.assertNotIn(BEARER, log, f"{job_name}: registry token leaked")
                if step.get("id") == "recheck":
                    for line in output.read_text().splitlines():
                        key, _, value = line.partition("=")
                        context[f"steps.recheck.outputs.{key}"] = value
                if kind == "manifest":
                    pushed += re.findall(r"^manifest push ghcr\.io/txehq/bifrost:(\S+)$", docker_log.read_text(), re.M)
                if result.returncode != 0:
                    return pushed, True  # later steps are skipped, as success() gates them
            elif kind in ("build", "mirror"):
                pushed.append(f"v{VERSION}{PUBLISHERS[job_name]}")
        return pushed, False

    def test_fresh_release_publishes_each_absent_tag(self):
        for job_name, suffix in PUBLISHERS.items():
            tag = f"v{VERSION}{suffix}"
            with self.subTest(job=job_name):
                if job_name.startswith("docker-manifest"):
                    pushed, failed = self.attempt(job_name, present=set())
                    self.assertFalse(failed)
                    self.assertEqual(sorted(pushed), sorted([tag, f"latest{suffix}"]))
                else:
                    pushed, failed = self.attempt(job_name, present=set())
                    self.assertFalse(failed)
                    self.assertEqual(pushed, [tag, tag])  # build, then the same-registry mirror

    def test_rerun_after_the_tag_landed_does_not_push_it_again(self):
        for job_name, suffix in PUBLISHERS.items():
            tag = f"v{VERSION}{suffix}"
            with self.subTest(job=job_name):
                pushed, failed = self.attempt(job_name, present={tag})
                self.assertFalse(failed)
                self.assertNotIn(tag, pushed)
                if job_name.startswith("docker-manifest"):
                    self.assertEqual(pushed, [f"latest{suffix}"])

    def test_architecture_job_failing_after_its_push_is_rerun_without_pushing(self):
        for job_name, suffix in PUBLISHERS.items():
            if job_name.startswith("docker-manifest"):
                continue
            tag = f"v{VERSION}{suffix}"
            with self.subTest(job=job_name):
                first, _ = self.attempt(job_name, present=set())
                self.assertIn(tag, first)
                # The push landed, then the job failed in a later step; the re-run sees
                # the tag on the registry although detection still says it is absent.
                second, failed = self.attempt(job_name, present={tag})
                self.assertFalse(failed)
                self.assertEqual(second, [])

    def test_manifest_job_failing_on_latest_is_rerun_without_republishing_the_version(self):
        for job_name in ("docker-manifest", "docker-manifest-ubi9"):
            suffix = PUBLISHERS[job_name]
            tag = f"v{VERSION}{suffix}"
            with self.subTest(job=job_name):
                first, failed = self.attempt(job_name, present=set(), fail_push=f"latest{suffix}")
                self.assertTrue(failed)
                self.assertEqual(first, [tag, f"latest{suffix}"])
                second, failed = self.attempt(job_name, present={tag})
                self.assertFalse(failed)
                self.assertEqual(second, [f"latest{suffix}"])
                self.assertEqual((first + second).count(tag), 1)

    def test_malformed_registry_token_blocks_publication(self):
        # A trailing newline the shell would strip: the gate must refuse the token, not
        # repair it, even though the registry would then report every tag absent.
        for job_name in PUBLISHERS:
            with self.subTest(job=job_name):
                pushed, failed = self.attempt(job_name, present=set(), token=f'200 0 {{"token":"{BEARER}\\n"}}')
                self.assertTrue(failed)
                self.assertEqual(pushed, [])

    def test_ambiguous_registry_blocks_publication(self):
        for job_name in PUBLISHERS:
            with self.subTest(job=job_name):
                pushed, failed = self.attempt(
                    job_name, present=set(), registry_error='503 0 {"errors":[{"code":"UNAVAILABLE"}]}'
                )
                self.assertTrue(failed)
                self.assertEqual(pushed, [])


if __name__ == "__main__":
    unittest.main()
