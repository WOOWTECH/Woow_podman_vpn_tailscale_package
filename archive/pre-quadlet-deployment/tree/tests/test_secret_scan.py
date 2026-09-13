import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SECRET = re.compile(
    rb"(?:(?:tskey-(?:auth|client|node)|hskey-auth)-[A-Za-z0-9_-]{12,}|"
    rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)",
    re.IGNORECASE,
)
NONEMPTY_CREDENTIAL = re.compile(rb"^(?:TS_AUTHKEY|HEADSCALE_PREAUTH_KEY)=[^\s#].+$", re.MULTILINE | re.IGNORECASE)
ALLOW_GENERIC_NAMES = {
    "scripts/headscale_json.py",
    "tests/test_secret_scan.py",
}


def git_names(*args):
    output = subprocess.check_output(["git", *args, "-z"], cwd=ROOT)
    return {item.decode() for item in output.split(b"\0") if item}


class SecretScan(unittest.TestCase):
    def test_no_repository_runtime_or_real_secret(self):
        names = set()
        for base, dirs, files in os.walk(ROOT):
            dirs[:] = [item for item in dirs if item != ".git"]
            for item in files:
                names.add(str((Path(base) / item).relative_to(ROOT)))
        bad = []
        for name in sorted(names):
            path = ROOT / name
            parts = Path(name).parts
            if Path(name).name in {".env", ".env.gateway"} or "backups" in parts:
                bad.append(f"forbidden artifact: {name}")
                continue
            lower_name = name.lower()
            if any(term in lower_name for term in ("preauth", "authkey")) and name not in ALLOW_GENERIC_NAMES:
                bad.append(f"key-bearing filename: {name}")
                continue
            if path.is_file():
                content = path.read_bytes()
                if SECRET.search(content) or (Path(name).name.startswith(".env") and NONEMPTY_CREDENTIAL.search(content)):
                    bad.append(f"secret-shaped content: {name}")
        self.assertEqual(bad, [])

    def test_operational_scanner_covers_ignored_runtime_without_echoing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir()
            secrets = [
                "".join(("ts", "key-", "auth-", "A" * 20)),
                "".join(("hs", "key-", "auth-", "B" * 20)),
                "TS_" + "AUTHKEY=opaque-runtime-value",
            ]
            for index, secret in enumerate(secrets):
                (root / f"runtime/state-{index}").write_text(secret)
            result = subprocess.run(["python3", "scripts/secret_scan.py", str(root)], cwd=ROOT, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            for secret in secrets:
                self.assertNotIn(secret, result.stdout + result.stderr)

    def test_worktree_and_staged_diffs_have_no_real_secret(self):
        for command in (["git", "diff", "--binary", "HEAD"], ["git", "diff", "--binary", "--cached"]):
            with self.subTest(command=" ".join(command)):
                diff = subprocess.run(command, cwd=ROOT, capture_output=True, check=True).stdout
                self.assertIsNone(SECRET.search(diff))

    def test_executable_source_modes(self):
        for path in (ROOT / "scripts").glob("*"):
            if path.is_file() and path.suffix in (".sh", ".py"):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755, path)
        self.assertEqual(stat.S_IMODE((ROOT / "entrypoint.sh").stat().st_mode), 0o755)

    def test_documented_operations_and_security_contract(self):
        text = (ROOT / "README.md").read_text()
        for heading in (
            "Gateway prerequisites",
            "Gateway configuration",
            "Deploy and verify",
            "Isolated live test",
            "User systemd and linger",
            "Backup and restore",
            "Gateway removal",
            "Troubleshooting",
            "Matter Server retirement gate",
        ):
            self.assertIn(heading, text)
        for required in (
            "Podman **4.9.3 or newer**",
            "Headscale server at exactly **0.29.3**",
            "container loopback is host loopback",
            "--tun=userspace-networking",
            "no TUN device",
            "tailnet TCP `18081` and `18069`",
            "public HTTP/HTTPS listeners are unchanged",
            "Tailscale web UI and Caddy are disabled",
            "reusable five-minute Headscale credential",
            "immediately expires and deletes",
            "steady-state container has no credential mount",
            "purging it requires enrollment of a new node",
            "scripts/deploy.sh",
            "scripts/verify.sh",
            "scripts/live-test.sh",
            "scripts/backup.sh",
            "scripts/restore.sh",
            "--retain-state",
            "--purge-state --confirm-purge",
            "git diff",
            "podman container inspect",
            "sanitiz",
        ):
            self.assertIn(required, text)


if __name__ == "__main__":
    unittest.main()
