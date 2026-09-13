import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/remove-matter-server.sh"
SOURCE = SCRIPT.read_text()


class MatterRemovalContract(unittest.TestCase):
    def test_literal_confirmation_is_required_before_commands(self):
        result = subprocess.run([str(SCRIPT)], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("literal --confirm-permanent-matter-removal is required", result.stderr)

    def test_first_gate_failure_performs_no_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fakebin = root / "bin"
            fakebin.mkdir()
            log = root / "commands"
            podman = fakebin / "podman"
            podman.write_text(
                "#!/bin/sh\nprintf 'podman %s\\n' \"$*\" >>\"$COMMAND_LOG\"\n"
                "case \"$*\" in 'ps -aq') exit 0;; *) exit 99;; esac\n"
            )
            systemctl = fakebin / "systemctl"
            systemctl.write_text(
                "#!/bin/sh\nprintf 'systemctl %s\\n' \"$*\" >>\"$COMMAND_LOG\"\n"
                "case \"$*\" in '--user list-unit-files --type=service --no-legend') exit 0;; *) exit 99;; esac\n"
            )
            python = fakebin / "python3"
            python.write_text("#!/bin/sh\nprintf 'python3 %s\\n' \"$*\" >>\"$COMMAND_LOG\"\nexit 1\n")
            for executable in (podman, systemctl, python):
                executable.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{fakebin}:{os.environ['PATH']}",
                "HOME": str(root / "home"),
                "XDG_RUNTIME_DIR": str(root / "run"),
                "COMMAND_LOG": str(log),
            }
            result = subprocess.run(
                [str(SCRIPT), "--confirm-permanent-matter-removal"],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            commands = log.read_text()
            self.assertNotIn("podman rm ", commands)
            self.assertNotIn("podman volume rm", commands)
            self.assertNotIn("podman image rm", commands)
            self.assertNotIn("systemctl --user disable", commands)

    def test_full_fake_success_failures_and_shared_resource_refusals(self):
        def fixture(directory):
            root = Path(directory) / "checkout"
            (root / "scripts").mkdir(parents=True)
            (root / "tests").mkdir()
            (root / "runtime").mkdir(mode=0o700)
            shutil.copy2(SCRIPT, root / "scripts/remove-matter-server.sh")
            (root / "entrypoint.sh").write_text("#!/bin/sh\n")
            (root / "runtime/gateway-self-id").write_text("gateway-self\n")
            home = Path(directory) / "home"
            units = home / ".config/systemd/user"
            units.mkdir(parents=True)
            image = "sha256:" + "a" * 64
            unit = units / "matter-server.service"
            unit.write_text(f"[Service]\nExecStart=/usr/bin/podman run --name matter-server --volume matter-server_data:/data {image}\n")
            log = Path(directory) / "commands"
            state = Path(directory) / "state.json"
            state.write_text(json.dumps({"matter": True, "volume": True, "image": True}))
            for name, body in {
                "verify.sh": '#!/bin/sh\nprintf "verify\\n" >>"$COMMAND_LOG"\n[ "${FAIL_AT:-}" != verify ]\n',
                "live-test.sh": '#!/bin/sh\nprintf "live\\n" >>"$COMMAND_LOG"\n[ "${FAIL_AT:-}" != live ]\n',
                "backup.sh": '#!/bin/sh\nprintf "backup\\n" >>"$COMMAND_LOG"\n[ "${FAIL_AT:-}" != backup ] || exit 8\n: >"$1"\n',
            }.items():
                p = root / "scripts" / name; p.write_text(body); p.chmod(0o755)
            fake = Path(directory) / "bin"; fake.mkdir()
            bash = fake / "bash"
            bash.write_text('#!/bin/sh\nprintf "bash %s\\n" "$*" >>"$COMMAND_LOG"\nif [ "${1:-}" = -n ] && [ "${FAIL_AT:-}" = bash-n ]; then exit 8; fi\nexec /bin/bash "$@"\n'); bash.chmod(0o755)
            remove = fake / "rm"
            remove.write_text('#!/bin/sh\nprintf "rm %s\\n" "$*" >>"$COMMAND_LOG"\nif [ "${FAIL_AT:-}" = unit-rm ] && [ "${2:-}" = "$UNIT" ]; then exit 8; fi\nexec /bin/rm "$@"\n'); remove.chmod(0o755)
            python = fake / "python3"
            python.write_text(textwrap.dedent('''#!/bin/sh
printf 'python3 %s\\n' "$*" >>"$COMMAND_LOG"
case "$*" in
 '-m unittest discover -s tests -v') [ "${FAIL_AT:-}" != unittest ];;
 '-m unittest tests.test_secret_scan -v') [ "${FAIL_AT:-}" != secret ];;
 *) exec /usr/bin/python3 "$@";;
esac
'''))
            python.chmod(0o755)
            git = fake / "git"; git.write_text('#!/bin/sh\nprintf "git %s\\n" "$*" >>"$COMMAND_LOG"\n[ "${FAIL_AT:-}" != git ]\n'); git.chmod(0o755)
            systemctl = fake / "systemctl"
            systemctl.write_text(textwrap.dedent('''#!/usr/bin/env python3
import os,sys
with open(os.environ['COMMAND_LOG'],'a') as f:f.write('systemctl '+' '.join(sys.argv[1:])+'\\n')
a=sys.argv[1:];fail=os.environ.get('FAIL_AT','')
if fail and fail in ('restart','disable','daemon') and fail in ' '.join(a): raise SystemExit(8)
if 'list-unit-files' in a:
 if fail=='list-units': raise SystemExit(8)
 print('matter-server.service enabled');raise SystemExit(0)
if 'show' in a:
 print(os.environ['UNIT'] if fail!='foreign-unit' else os.path.join(os.environ['HOME'],'.config/systemd/user/foreign.service'));raise SystemExit(0)
raise SystemExit(0)
''')); systemctl.chmod(0o755)
            podman = fake / "podman"
            podman.write_text(textwrap.dedent('''#!/usr/bin/env python3
import json,os,sys
p=os.environ['STATE'];s=json.load(open(p));a=sys.argv[1:];joined=' '.join(a);fail=os.environ.get('FAIL_AT','')
with open(os.environ['COMMAND_LOG'],'a') as f:f.write('podman '+joined+'\\n')
def save(): open(p,'w').write(json.dumps(s))
image='sha256:'+'a'*64
def matter(): return {'Id':'matter-id','Name':'/matter-server','Image':image,'State':{'Running':True},'Mounts':[{'Type':'volume','Name':'matter-server_data','Destination':'/data'}]}
def gateway():
 obj={'Id':'gateway-id','Name':'/woow-tailscale-gateway','Image':'sha256:'+'b'*64,'State':{'Running':True},'Mounts':[]}
 if fail=='shared-image': obj['Image']=image
 if fail=='shared-volume': obj['Mounts']=[{'Type':'volume','Name':'matter-server_data','Destination':'/other'}]
 return obj
should_fail=(
 (fail=='snapshot' and a[:2]==['ps','-aq']) or
 (fail=='matter-inspect' and a[:3]==['container','inspect','matter-server']) or
 (fail=='volume-inspect' and a[:3]==['volume','inspect','matter-server_data']) or
 (fail=='status' and bool(a) and a[0]=='exec')
)
if should_fail: raise SystemExit(8)
if a[:2]==['ps','-aq']:
 print('gateway-id');
 if s['matter']: print('matter-id')
 raise SystemExit(0)
if a and a[0]=='inspect':
 ident=a[1]; print(json.dumps([matter() if ident=='matter-id' else gateway()]));raise SystemExit(0)
if a[:2]==['container','inspect']:
 if s['matter']: print(json.dumps([matter()]));raise SystemExit(0)
 raise SystemExit(1)
if a[:2]==['volume','inspect']:
 if s['volume']: print(json.dumps([{'Name':'matter-server_data'}]));raise SystemExit(0)
 raise SystemExit(1)
if a[:2]==['image','inspect']: raise SystemExit(0 if s['image'] else 1)
if a and a[0]=='exec': print('{"Self":{"ID":"gateway-self"}}');raise SystemExit(0)
if a[:2]==['rm','matter-server']:
 if fail=='rm-container': raise SystemExit(8)
 s['matter']=False;save();raise SystemExit(0)
if a[:2]==['volume','rm']:
 if fail=='rm-volume': raise SystemExit(8)
 s['volume']=False;save();raise SystemExit(0)
if a[:2]==['image','rm']:
 if fail=='rm-image': raise SystemExit(8)
 s['image']=False;save();raise SystemExit(0)
raise SystemExit(2)
''')); podman.chmod(0o755)
            return root, home, unit, fake, log, state

        def run_case(directory, failure=""):
            root, home, unit, fake, log, state = fixture(directory)
            env = {**os.environ, "PATH": f"{fake}:{os.environ['PATH']}", "HOME": str(home), "XDG_RUNTIME_DIR": str(Path(directory)/"run"), "COMMAND_LOG": str(log), "STATE": str(state), "UNIT": str(unit), "FAIL_AT": failure}
            result = subprocess.run([str(root/"scripts/remove-matter-server.sh"), "--confirm-permanent-matter-removal"], cwd=root, env=env, text=True, capture_output=True)
            return result, log, state, unit

        with tempfile.TemporaryDirectory() as directory:
            result, log, state, unit = run_case(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(state.read_text()), {"matter": False, "volume": False, "image": False})
            self.assertFalse(unit.exists()); self.assertIn("Matter Server permanently removed", result.stdout)
        for failure in ("snapshot", "list-units", "unittest", "bash-n", "git", "secret", "verify", "live", "status", "restart", "backup", "matter-inspect", "volume-inspect", "shared-image", "shared-volume", "foreign-unit", "disable", "unit-rm", "daemon", "rm-container", "rm-volume", "rm-image"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                result, log, state, unit = run_case(directory, failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                if failure in ("snapshot", "list-units", "unittest", "bash-n", "git", "secret", "verify", "live", "status", "restart", "backup", "matter-inspect", "volume-inspect", "shared-image", "shared-volume", "foreign-unit"):
                    commands = log.read_text()
                    self.assertNotIn("podman rm matter-server", commands)
                    self.assertNotIn("podman volume rm matter-server_data", commands)
                    self.assertNotIn("podman image rm", commands)
                    self.assertTrue(unit.exists())

    def test_all_fresh_gates_precede_discovery_and_mutation(self):
        gates = [
            "python3 -m unittest discover -s tests -v",
            "python3 -m unittest tests.test_secret_scan -v",
            "scripts/verify.sh",
            "scripts/live-test.sh",
            "systemctl --user restart woow-tailscale-gateway.service",
            "scripts/backup.sh \"$backup\"",
        ]
        first_mutation = SOURCE.index('systemctl --user disable --now "$matter_unit"')
        for gate in gates:
            self.assertLess(SOURCE.index(gate), first_mutation, gate)
        self.assertLess(SOURCE.index("podman container inspect matter-server"), first_mutation)
        self.assertLess(SOURCE.index("Matter image is shared"), first_mutation)
        self.assertLess(SOURCE.index("Matter volume is shared"), first_mutation)

    def test_removal_is_exact_and_unrelated_state_is_compared(self):
        for command in (
            "podman rm matter-server",
            "podman volume rm matter-server_data",
            'podman image rm "$image_id"',
            'rm -- "${units[0]}"',
        ):
            self.assertIn(command, SOURCE)
        self.assertNotIn("podman rm -a", SOURCE)
        self.assertNotIn("podman volume rm *", SOURCE)
        self.assertIn("before-mutation.json", SOURCE)
        self.assertIn("after-mutation.json", SOURCE)
        self.assertIn("unrelated container state changed", SOURCE)
        self.assertIn("Matter is not recreated automatically", SOURCE)
        self.assertIn('.Destination=="/data"', SOURCE)
        self.assertIn("select(.Name==\"matter-server_data\")]|length'", SOURCE)
        self.assertIn("words[0].lstrip('-:@+!')", SOURCE)
        self.assertIn("vals('--name') != ['matter-server']", SOURCE)
        self.assertIn("['matter-server_data','/data']", SOURCE)


if __name__ == "__main__":
    unittest.main()
