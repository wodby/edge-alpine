#!/usr/bin/env python3
"""Exercise GitHub release publication against a recording gh executable."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "wodby/edge-alpine"
TAGS = ["2.7.10", "3.0.9", "3.0.10", "3.0.38", "r0", "v1.3.0"]
MESSAGE = """Changes since 3.0.37

- NGINX base image: wodby/nginx:1.31-r18 -> wodby/nginx:1.31-r19.
-----BEGIN SSH SIGNATURE-----
U1NIU0lHAAAAAQ==
-----END SSH SIGNATURE-----
"""

GH = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
state = json.loads(os.environ["GH_STATE"])
with open(os.environ["COMMAND_LOG"], "a") as output:
    output.write(json.dumps(args) + "\n")
if args[:2] == ["release", "view"]:
    sys.exit(0 if args[2] in state["releases"] else 1)
if args[:2] == ["release", "create"]:
    notes = args[args.index("--notes-file") + 1]
    with open(os.environ["NOTES_LOG"], "w") as output:
        output.write(open(notes).read())
    sys.exit(0)
if args[0] == "api":
    path = [arg for arg in args[1:] if not arg.startswith("-") and arg.startswith("repos/")][0]
    if path.endswith("/tags"):
        print("\n".join(state["tags"]))
    elif "/git/ref/tags/" in path:
        print(state["type"] + " abc123")
    elif path.endswith("/git/tags/abc123"):
        print(state["message"])
    else:
        sys.exit("Unexpected API path: " + path)
    sys.exit(0)
sys.exit("Unexpected gh command: " + repr(args))
"""


def run(tag, policy, releases=(), kind="tag", message=MESSAGE, ref=None):
    """Run the release script and return its result, gh commands and notes."""
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        log, notes = directory / "commands.jsonl", directory / "notes.md"
        gh = directory / "gh"
        gh.write_text(GH)
        gh.chmod(0o755)
        env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                   COMMAND_LOG=str(log), NOTES_LOG=str(notes),
                   GH_STATE=json.dumps({"releases": list(releases), "tags": TAGS,
                                        "type": kind, "message": message}),
                   GITHUB_REF=ref or "refs/tags/" + tag, GITHUB_REF_NAME=tag,
                   GH_REPO=REPO, RELEASE_LATEST=policy)
        result = subprocess.run(["bash", ".github/actions/github-release.sh"], cwd=ROOT,
                                env=env, text=True, capture_output=True)
        commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        created = [command for command in commands if command[:2] == ["release", "create"]]
        return result, created, notes.read_text() if notes.exists() else None


def latest_flag(created):
    """Return the --latest value passed to the single release create call."""
    assert len(created) == 1, created
    return [arg for arg in created[0] if arg.startswith("--latest")][0]


# The highest product version becomes Latest; older or legacy tags never do.
result, created, notes = run("3.0.38", "highest")
assert result.returncode == 0, result.stderr
assert latest_flag(created) == "--latest=true", created
assert created[0][:3] == ["release", "create", "3.0.38"] and "--verify-tag" in created[0], created
assert notes == "Changes since 3.0.37\n\n- NGINX base image: wodby/nginx:1.31-r18 -> wodby/nginx:1.31-r19.\n", notes

result, created, _ = run("3.0.10", "highest")
assert result.returncode == 0 and latest_flag(created) == "--latest=false", (result.stderr, created)

result, created, _ = run("2.7.10", "never")
assert result.returncode == 0 and latest_flag(created) == "--latest=false", (result.stderr, created)

# Existing releases are left untouched so a rerun cannot overwrite edited notes.
result, created, _ = run("3.0.38", "highest", releases=["3.0.38"])
assert result.returncode == 0 and not created, (result.stderr, created)

# Revision and legacy tags, lightweight tags and empty messages are refused.
for tag in ["r0", "v1.3.0"]:
    result, created, _ = run(tag, "highest")
    assert result.returncode != 0 and not created, (tag, created)
result, created, _ = run("3.0.38", "highest", ref="refs/heads/master")
assert result.returncode != 0 and not created, created
result, created, _ = run("3.0.38", "highest", kind="commit")
assert result.returncode != 0 and not created, created
result, created, _ = run("3.0.38", "highest", message="-----BEGIN SSH SIGNATURE-----\nx\n-----END SSH SIGNATURE-----")
assert result.returncode != 0 and not created, created
result, created, _ = run("3.0.38", "sometimes")
assert result.returncode != 0 and not created, created

print("github-release: ok")
