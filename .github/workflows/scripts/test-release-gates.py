#!/usr/bin/env python3
"""Replays release-pipeline.yml job conditions for a transport-only release.

Every Docker image and transport release builds from the workspace's core, framework
and plugins (both Dockerfiles copy go.work and the module trees), so their suites have
to run and pass before an image is published, even when no module publishes itself
because its changelog is empty. This evaluates the real `if:` expressions, and the
detect-changes outputs they read, against scripted job results; no runner is involved.

Usage: python3 test-release-gates.py
"""
import ast
import re
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parent.parent / "release-pipeline.yml"
JOBS = yaml.safe_load(WORKFLOW.read_text())["jobs"]

# Suites an image or transport release embeds the code of, and the skip flags that may
# legitimately skip each one (an admin skip_tests dispatch, or --skip-core-test for the
# suites that call live providers).
EMBEDDED_SUITES = {
    "test-core": ("skip-tests", "skip-core-test"),
    "test-core-integrations": ("skip-tests", "skip-core-test"),
    "test-core-unit": ("skip-tests",),
    "resolve-cli-versions": ("skip-tests",),
    "test-cli-harness": ("skip-tests",),
    "test-framework": ("skip-tests",),
    "test-plugins": ("skip-tests",),
}
PUBLISHERS = ["bifrost-http-prep", "docker-build-amd64", "docker-build-arm64", "docker-build-ubi9-amd64", "docker-build-ubi9-arm64"]


def evaluate(expression, context):
    """Evaluates a GitHub Actions expression over context, which maps dotted names
    (needs.x.result, needs.x.outputs.y, steps.x.outputs.y) to strings."""
    expr = expression.strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2]
    unknown = []

    def ref(match):
        name = match.group(0)
        if name not in context:
            unknown.append(name)
        return repr(context.get(name, ""))

    expr = re.sub(r"\b(?:needs|steps)\.[A-Za-z0-9_-]+\.(?:result|outputs\.[A-Za-z0-9_-]+)", ref, expr)
    expr = expr.replace("always()", "True").replace("!cancelled()", "True").replace("cancelled()", "False")
    expr = expr.replace("&&", " and ").replace("||", " or ").replace("!=", " __NE__ ").replace("==", " __EQ__ ")
    expr = expr.replace("!", " not ").replace("__NE__", "!=").replace("__EQ__", "==")
    if unknown:
        raise AssertionError(f"expression reads unset context {sorted(set(unknown))}: {expression}")
    value = _evaluate_node(ast.parse(" ".join(expr.split()), mode="eval").body)
    if isinstance(value, str):
        return value
    return "true" if value else "false"


def _evaluate_node(node):
    """Walks the translated expression; anything beyond literals, and/or/not and
    ==/!= is rejected, so no workflow text can run as code."""
    if isinstance(node, ast.Constant) and isinstance(node.value, (str, bool)):
        return node.value
    if isinstance(node, ast.BoolOp):
        values = [_evaluate_node(v) for v in node.values]
        return all(values) if isinstance(node.op, ast.And) else any(values)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        return not _evaluate_node(node.operand)
    if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
        equal = _evaluate_node(node.left) == _evaluate_node(node.comparators[0])
        return equal if isinstance(node.ops[0], ast.Eq) else not equal
    raise AssertionError(f"unsupported expression element {ast.dump(node)}")


def transport_only_context(results, skip_tests="false", skip_core_test="false"):
    """A transport/Docker release with every module changelog empty."""
    flags = {
        "core-needs-release": "false",
        "framework-needs-release": "false",
        "plugins-need-release": "false",
        "bifrost-http-needs-release": "true",
        "docker-needs-release": "true",
    }
    context = {f"steps.detect.outputs.{k}": v for k, v in flags.items()}
    context.update({f"needs.detect-changes.outputs.{k}": v for k, v in flags.items()})
    for name, expression in JOBS["detect-changes"]["outputs"].items():
        if name.endswith("needs-tests"):
            context[f"needs.detect-changes.outputs.{name}"] = evaluate(str(expression), context)
    context.update({
        "needs.check-skip.outputs.should-skip": "false",
        "needs.check-skip.outputs.skip-tests": skip_tests,
        "needs.check-skip.outputs.skip-core-test": skip_core_test,
        "needs.detect-changes.result": "success",
        "needs.detect-changes.outputs.changed-plugins": "[]",
    })
    for job in JOBS:
        context.setdefault(f"needs.{job}.result", results.get(job, "success"))
    return context


class TransportOnlyReleaseGates(unittest.TestCase):
    def test_embedded_suites_run_for_a_transport_only_release(self):
        context = transport_only_context({})
        for suite in EMBEDDED_SUITES:
            with self.subTest(suite=suite):
                self.assertEqual(evaluate(str(JOBS[suite]["if"]), context), "true")

    def test_publishing_requires_every_embedded_suite_to_pass(self):
        context = transport_only_context({})
        for publisher in PUBLISHERS:
            with self.subTest(publisher=publisher):
                self.assertEqual(evaluate(str(JOBS[publisher]["if"]), context), "true")

    def test_an_unexplained_skip_or_failure_blocks_publishing(self):
        for suite in EMBEDDED_SUITES:
            for result in ("skipped", "failure", "cancelled"):
                if suite == "test-core" and result == "failure":
                    continue  # the flaky-approval path, covered below
                context = transport_only_context({suite: result, "approve-flaky-test-core": "skipped"})
                for publisher in PUBLISHERS:
                    with self.subTest(suite=suite, result=result, publisher=publisher):
                        self.assertEqual(evaluate(str(JOBS[publisher]["if"]), context), "false")

    def test_a_failed_test_core_publishes_only_after_flaky_approval(self):
        for approval, expected in (("success", "true"), ("skipped", "false"), ("failure", "false")):
            context = transport_only_context({"test-core": "failure", "approve-flaky-test-core": approval})
            for publisher in PUBLISHERS:
                with self.subTest(approval=approval, publisher=publisher):
                    self.assertEqual(evaluate(str(JOBS[publisher]["if"]), context), expected)

    def test_explicit_skip_flags_still_allow_their_skips(self):
        everything_skipped = {suite: "skipped" for suite in EMBEDDED_SUITES}
        context = transport_only_context(everything_skipped, skip_tests="true")
        for publisher in PUBLISHERS:
            with self.subTest(flag="skip-tests", publisher=publisher):
                self.assertEqual(evaluate(str(JOBS[publisher]["if"]), context), "true")
        live_skipped = {"test-core": "skipped", "test-core-integrations": "skipped", "approve-flaky-test-core": "skipped"}
        context = transport_only_context(live_skipped, skip_core_test="true")
        for publisher in PUBLISHERS:
            with self.subTest(flag="skip-core-test", publisher=publisher):
                self.assertEqual(evaluate(str(JOBS[publisher]["if"]), context), "true")
        # --skip-core-test covers only the live suites.
        context = transport_only_context({**live_skipped, "test-core-unit": "skipped"}, skip_core_test="true")
        for publisher in PUBLISHERS:
            with self.subTest(flag="skip-core-test does not cover unit", publisher=publisher):
                self.assertEqual(evaluate(str(JOBS[publisher]["if"]), context), "false")


if __name__ == "__main__":
    unittest.main()
