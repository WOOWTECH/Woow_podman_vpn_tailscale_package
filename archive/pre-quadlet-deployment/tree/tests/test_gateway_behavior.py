import hashlib
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from scripts.service_ownership import normalized_immutable_reference

ROOT = Path(__file__).resolve().parents[1]


class FakeCommands(unittest.TestCase):
    def make_command(self, directory, name, body):
        path = Path(directory) / name
        lines = body.splitlines()
        normalized = lines[0] + "\n" + textwrap.dedent("\n".join(lines[1:])) + "\n"
        path.write_text(normalized)
        path.chmod(0o755)
        return path

    def run_with_path(self, args, fake_dir, **kwargs):
        env = {**os.environ, "PATH": f"{fake_dir}:{os.environ['PATH']}", **kwargs.pop("env", {})}
        cwd = kwargs.pop("cwd", ROOT)
        return subprocess.run(args, cwd=cwd, text=True, capture_output=True, env=env, **kwargs)

    def test_gateway_route_environment_is_rejected_and_render_omits_routes(self):
        with tempfile.TemporaryDirectory() as d:
            env = {
                "STATE_DIR": d,
                "TS_GATEWAY_MODE": "true",
                "TS_USERSPACE_NETWORKING": "true",
                "TS_WEB_UI": "false",
                "TS_ACCEPT_DNS": "true",
                "TS_ADVERTISE_CONNECTOR": "false",
                "TS_ALWAYS_USE_DERP": "false",
                "TS_SERVE_TCP_18081": "127.0.0.1:18081",
                "TS_SERVE_TCP_18069": "127.0.0.1:18069",
                "TS_ACCEPT_ROUTES": "false",
            }
            result = subprocess.run(["bash", "entrypoint.sh"], cwd=ROOT, text=True, capture_output=True, env={**os.environ, **env})
            self.assertEqual(result.returncode, 2)
            self.assertIn("route environment flags must be omitted", result.stderr)
        from scripts.gateway_config import parse, runtime
        conf = runtime(parse(ROOT / ".env.gateway.example"))
        forbidden = {"TS_ACCEPT_ROUTES", "TS_ADVERTISE_ROUTES", "TS_ADVERTISE_EXIT_NODE", "TS_SNAT_SUBNET_ROUTES", "TS_STATEFUL_FILTERING", "TS_EXIT_NODE"}
        self.assertTrue(forbidden.isdisjoint(conf))

    def test_reconcile_stale_container_is_idempotent_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            state = Path(d) / "state"
            state.write_text("stale")
            fake = self.make_command(d, "podman", textwrap.dedent("""#!/usr/bin/env python3
                import json,os,sys
                a=sys.argv[1:]; state=os.environ['FAKE_STATE']; root=os.environ['CHECKOUT']
                exists=os.path.exists(state)
                if a[:2]==['container','inspect']:
                    if not exists: print('no such container',file=sys.stderr);raise SystemExit(1)
                    obj={'Name':'/woow-tailscale-gateway','Labels':{'org.woow-tailscale.project':'woow-tailscale-gateway','org.woow-tailscale.role':'gateway','org.woow-tailscale.managed-by':'woow-gateway-lifecycle','org.woow-tailscale.checkout':root},'Mounts':[{'Destination':'/var/lib/tailscale','Name':'woow-tailscale-gateway-state'}],'State':{'Running':os.environ.get('FAKE_ACTIVE')=='1'}}
                    print(json.dumps([obj]));raise SystemExit(0)
                if a[:2]==['container','rm']:
                    if os.environ.get('FAIL_RM')=='1': raise SystemExit(1)
                    os.unlink(state);raise SystemExit(0)
                raise SystemExit(2)
            """))
            env = {"FAKE_STATE": str(state), "CHECKOUT": str(ROOT)}
            first = self.run_with_path(["python3", "scripts/resource_ownership.py", "reconcile-container", str(ROOT)], d, env=env)
            second = self.run_with_path(["python3", "scripts/resource_ownership.py", "reconcile-container", str(ROOT)], d, env=env)
            self.assertEqual((first.returncode, second.returncode), (0, 0))
            state.write_text("stale")
            failed = self.run_with_path(["python3", "scripts/resource_ownership.py", "reconcile-container", str(ROOT)], d, env={**env, "FAIL_RM": "1"})
            self.assertNotEqual(failed.returncode, 0)
            self.assertTrue(state.exists())
            active = self.run_with_path(["python3", "scripts/resource_ownership.py", "reconcile-container", str(ROOT)], d, env={**env, "FAKE_ACTIVE": "1"})
            self.assertNotEqual(active.returncode, 0)
            self.assertTrue(state.exists())

    def test_live_cleanup_removes_and_verifies_every_object_and_injects_failure(self):
        with tempfile.TemporaryDirectory() as d:
            state = Path(d) / "objects.json"
            initial = {"container": True, "volume": True, "network": True, "keys": [7], "nodes": [9]}
            state.write_text(json.dumps(initial))
            self.make_command(d, "podman", textwrap.dedent("""#!/usr/bin/env python3
                import json,os,sys
                p=os.environ['FAKE_STATE'];s=json.load(open(p));a=sys.argv[1:]
                def save(): open(p,'w').write(json.dumps(s))
                if a[:2]==['rm','-f']:
                    s['container']=False;save();raise SystemExit(0)
                if len(a)>2 and a[1]=='inspect':
                    kind=a[0]; present=s.get(kind,False)
                    if present:
                        labels={'org.woow-tailscale.project':'woow-tailscale-gateway','org.woow-tailscale.role':'live-test','org.woow-tailscale.managed-by':'woow-gateway-lifecycle','org.woow-tailscale.invocation':'inv-1'}
                        print(json.dumps([{'Labels':labels}]));raise SystemExit(0)
                    print('no such '+kind,file=sys.stderr);raise SystemExit(1)
                if a[:2]==['volume','rm']:
                    if os.environ.get('FAIL_VOLUME')=='1': raise SystemExit(1)
                    s['volume']=False;save();raise SystemExit(0)
                if a[:2]==['network','rm']:
                    s['network']=False;save();raise SystemExit(0)
                if a and a[0]=='exec':
                    if 'preauthkeys' in a:
                        op=a[a.index('preauthkeys')+1]
                        if op=='delete': s['keys']=[x for x in s['keys'] if str(x)!=a[-1]];save()
                        if op=='list': print(json.dumps([{'id':x} for x in s['keys']]))
                        raise SystemExit(0)
                    if 'nodes' in a:
                        op=a[a.index('nodes')+1]
                        if op=='delete': s['nodes']=[x for x in s['nodes'] if str(x)!=a[-1]];save()
                        if op=='list': print(json.dumps([{'id':x,'given_name':'test','ip_addresses':['100.64.0.2']} for x in s['nodes']]))
                        raise SystemExit(0)
                raise SystemExit(2)
            """))
            args = ["python3", "scripts/live_cleanup.py", "--headscale", "headscale", "--invocation", "inv-1", "--container", "client", "--container-created", "--volume", "volume", "--volume-created", "--network", "network", "--network-created", "--key-id", "7", "--key-required", "--node-id", "9", "--node-hostname", "test", "--node-ip", "100.64.0.2"]
            env = {"FAKE_STATE": str(state)}
            first = self.run_with_path(args, d, env=env)
            second = self.run_with_path(args, d, env=env)
            self.assertEqual((first.returncode, second.returncode), (0, 0))
            self.assertEqual(json.loads(state.read_text()), {"container": False, "volume": False, "network": False, "keys": [], "nodes": []})
            state.write_text(json.dumps(initial))
            failed = self.run_with_path(args, d, env={**env, "FAIL_VOLUME": "1"})
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("test volume", failed.stderr)
            state.write_text(json.dumps(initial))
            foreign = self.run_with_path(["python3", "scripts/live_cleanup.py", "--headscale", "headscale", "--invocation", "other", "--container", "client", "--container-created"], d, env=env)
            self.assertNotEqual(foreign.returncode, 0)
            self.assertTrue(json.loads(state.read_text())["container"])
            baseline = self.run_with_path(["python3", "scripts/live_cleanup.py", "--headscale", "headscale", "--invocation", "inv-1", "--node-hostname", "test", "--baseline-node-id", "9"], d, env=env)
            self.assertEqual(baseline.returncode, 0, baseline.stderr)
            self.assertEqual(json.loads(state.read_text())["nodes"], [9])

    def test_headscale_identity_disambiguation_and_active_key_detection(self):
        with tempfile.TemporaryDirectory() as d:
            nodes = Path(d) / "nodes.json"
            nodes.write_text(json.dumps([
                {"id": 1, "given_name": "gateway", "ip_addresses": ["100.64.0.1"]},
                {"id": 2, "given_name": "gateway", "ip_addresses": ["100.64.0.2"]},
            ]))
            ambiguous = subprocess.run(["python3", "scripts/headscale_json.py", "find-node", str(nodes), "gateway"], cwd=ROOT, capture_output=True)
            exact = subprocess.run(["python3", "scripts/headscale_json.py", "find-node", str(nodes), "gateway", "--ip", "100.64.0.2"], cwd=ROOT, text=True, capture_output=True)
            self.assertNotEqual(ambiguous.returncode, 0)
            self.assertEqual((exact.returncode, exact.stdout.strip()), (0, "2"))
            keys = Path(d) / "keys.json"
            keys.write_text(json.dumps([{"id": 7, "reusable": True, "expiration": "2999-01-01T00:00:00Z"}]))
            active = subprocess.run(["python3", "scripts/headscale_json.py", "assert-no-active-reusable", str(keys)], cwd=ROOT, capture_output=True)
            self.assertNotEqual(active.returncode, 0)
            keys.write_text(json.dumps([{"id": 7, "reusable": True, "expiration": "2000-01-01T00:00:00Z"}]))
            expired = subprocess.run(["python3", "scripts/headscale_json.py", "assert-no-active-reusable", str(keys)], cwd=ROOT, capture_output=True)
            self.assertEqual(expired.returncode, 0)

    def test_service_ownership_normalizes_only_optional_image_tags(self):
        digest = "1" * 64
        expected = normalized_immutable_reference(
            f"docker.io/library/odoo:18.0@sha256:{digest}"
        )
        self.assertEqual(
            normalized_immutable_reference(f"docker.io/library/odoo@sha256:{digest}"),
            expected,
        )
        self.assertEqual(
            normalized_immutable_reference(f"docker.io/library/odoo:display@sha256:{digest}"),
            expected,
        )
        self.assertNotEqual(
            normalized_immutable_reference(f"quay.io/library/odoo@sha256:{digest}"),
            expected,
        )
        self.assertNotEqual(
            normalized_immutable_reference(f"docker.io/library/odoo@sha256:{'2' * 64}"),
            expected,
        )
        for invalid in (
            "docker.io/library/odoo:18.0",
            f"docker.io/library/odoo:18.0@sha256:{digest}@sha256:{digest}",
            f"docker.io/library/odoo:18.0@sha256:{digest[:-1]}",
            f"docker.io/library/odoo:18.0@sha256:{digest.upper().replace('1', 'A')}",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                normalized_immutable_reference(invalid)

    def test_service_ownership_checks_rendered_cross_package_contracts(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "home"
            units = home / ".config/systemd/user"
            units.mkdir(parents=True)
            fixtures = ROOT / "tests/fixtures/service_ownership"
            npm = home / "Woow_podman_nginxpm"
            odoo = home / "Woow_podman_odoo"
            (npm / "systemd").mkdir(parents=True)
            (npm / ".state").mkdir()
            (odoo / "systemd").mkdir(parents=True)
            npm_template = (fixtures / "nginx-proxy-manager.service").read_text()
            odoo_template = (fixtures / "odoo18.service.in").read_text()
            (npm / "systemd/nginx-proxy-manager.service").write_text(npm_template)
            (odoo / "systemd/odoo18.service.in").write_text(odoo_template)
            (npm / "docker-compose.yml").write_text("services: {}\n")
            (odoo / "docker-compose.yml").write_text("services: {}\n")
            owner = hashlib.sha256(f"woow-nginxpm-owner-v1:{npm}".encode()).hexdigest()
            (npm / ".state/owner-id").write_text(owner + "\n")
            (npm / ".state/checkout").write_text(str(npm) + "\n")
            (npm / ".state/owner-id").chmod(0o600)
            (npm / ".state/checkout").chmod(0o600)
            (units / "nginx-proxy-manager.service").write_text(npm_template.replace("@REPO_ROOT@", str(npm)))
            (units / "odoo18.service").write_text(odoo_template.replace("@PROJECT_ROOT@", str(odoo)))
            self.make_command(d, "systemctl", """#!/usr/bin/env python3
                import os,sys
                a=sys.argv[1:]
                if 'is-active' in a and os.environ.get('BAD_ACTIVE')==a[-1]: raise SystemExit(3)
                if 'show' in a: print(os.path.join(os.environ['HOME'],'.config/systemd/user',a[-1]))
            """)
            self.make_command(d, "podman", """#!/usr/bin/env python3
                import json,os,sys
                root=os.environ['FIXTURES']; home=os.environ['HOME']; uid=str(os.getuid()); owner=os.environ['NPM_OWNER']
                a=sys.argv[1:]; name=a[-1]
                if a[:2]==['image','inspect']:
                    data=json.load(open(os.path.join(root,'images.inspect.json')))[name]
                    print(json.dumps(data));raise SystemExit(0)
                file={'npm-app':'npm-app.inspect.json','odoo18-web':'odoo18-web.inspect.json'}[name]
                text=open(os.path.join(root,file)).read().replace('@HOME@',home).replace('@UID@',uid).replace('@NPM_OWNER@',owner)
                data=json.loads(text); obj=data[0]
                bad=os.environ.get('BAD_CONTRACT')
                if bad=='binding': obj['HostConfig']['PortBindings'][next(iter(obj['HostConfig']['PortBindings']))][0]['HostIp']='192.0.2.10'
                if bad=='owner':
                    key='io.woow.nginxpm.owner' if name=='npm-app' else 'io.woowtech.owner';obj['Config']['Labels'][key]='foreign'
                if bad=='checkout': obj['Config']['Labels']['com.docker.compose.project.config_files']='/foreign/docker-compose.yml'
                if bad=='mount': obj['Mounts'][0]['Destination']='/foreign'
                if bad=='image': obj['Image']='sha256:'+'e'*64
                if bad in ('image-repository','image-digest','image-tag-only'):
                    refs=[obj['Config']['Image'],obj['ImageName']]
                    if bad=='image-repository': refs=[ref.replace('docker.io/','quay.io/',1) for ref in refs]
                    if bad=='image-digest': refs=[ref[:-1]+('0' if ref[-1]!='0' else '1') for ref in refs]
                    if bad=='image-tag-only': refs=[ref.split('@',1)[0]+':latest' for ref in refs]
                    obj['Config']['Image'],obj['ImageName']=refs
                print(json.dumps(data))
            """)
            base = {"HOME": str(home), "FIXTURES": str(fixtures), "NPM_OWNER": owner}
            good = self.run_with_path(["python3", "scripts/service_ownership.py"], d, env=base)
            self.assertEqual(good.returncode, 0, good.stderr)
            for bad in (
                "binding", "owner", "checkout", "mount", "image",
                "image-repository", "image-digest", "image-tag-only",
            ):
                with self.subTest(bad=bad):
                    result = self.run_with_path(["python3", "scripts/service_ownership.py"], d, env={**base, "BAD_CONTRACT": bad})
                    self.assertNotEqual(result.returncode, 0, result.stderr)
            inactive = self.run_with_path(["python3", "scripts/service_ownership.py"], d, env={**base, "BAD_ACTIVE": "odoo18.service"})
            self.assertNotEqual(inactive.returncode, 0)
            installed = units / "odoo18.service"
            original = installed.read_text()
            installed.write_text(original.replace("TimeoutStopSec=120", "TimeoutStopSec=121"))
            foreign_unit = self.run_with_path(["python3", "scripts/service_ownership.py"], d, env=base)
            self.assertNotEqual(foreign_unit.returncode, 0)
            installed.write_text(original)
            (npm / ".state/checkout").write_text("/foreign\n")
            foreign_repo = self.run_with_path(["python3", "scripts/service_ownership.py"], d, env=base)
            self.assertNotEqual(foreign_repo.returncode, 0)

    def test_restore_rollback_verifies_identity_and_retains_failed_rollback_archive(self):
        with tempfile.TemporaryDirectory() as d:
            checkout = Path(d) / "checkout"
            (checkout / "scripts").mkdir(parents=True)
            (checkout / "runtime").mkdir(mode=0o700)
            (checkout / "runtime/gateway-self-id").write_text("old-self\n")
            (checkout / "runtime/gateway-self-id").chmod(0o600)
            for name in ("restore.sh", "resource_ownership.py"):
                target = checkout / "scripts" / name
                target.write_bytes((ROOT / "scripts" / name).read_bytes()); target.chmod(0o755)
            verify_count = Path(d) / "verify-count"
            (checkout / "scripts/verify.sh").write_text("""#!/bin/sh
                n=0; [ ! -f "$VERIFY_COUNT" ] || n=$(cat "$VERIFY_COUNT"); n=$((n+1)); echo "$n" >"$VERIFY_COUNT"
                if [ "${FAIL_ROLLBACK_VERIFY:-0}" = 1 ] && [ "$n" -ge 2 ]; then exit 1; fi
                exit 0
            """)
            # Normalize the indented fake verify script.
            raw = (checkout / "scripts/verify.sh").read_text().splitlines()
            (checkout / "scripts/verify.sh").write_text(raw[0] + "\n" + textwrap.dedent("\n".join(raw[1:])) + "\n")
            (checkout / "scripts/verify.sh").chmod(0o755)
            identity = Path(d) / "identity"; identity.write_text("old-self")
            self.make_command(d, "systemctl", """#!/bin/sh
                exit 0
            """)
            self.make_command(d, "podman", """#!/usr/bin/env python3
                import json,os,sys
                a=sys.argv[1:];root=os.environ['CHECKOUT'];identity=os.environ['IDENTITY']
                labels={'org.woow-tailscale.project':'woow-tailscale-gateway','org.woow-tailscale.managed-by':'woow-gateway-lifecycle','org.woow-tailscale.checkout':root}
                if a[:2]==['container','inspect']:
                    print(json.dumps([{'Name':'/woow-tailscale-gateway','Labels':{**labels,'org.woow-tailscale.role':'gateway'},'Mounts':[{'Destination':'/var/lib/tailscale','Name':'woow-tailscale-gateway-state'}],'State':{'Running':True}}]));raise SystemExit(0)
                if a[:2]==['volume','inspect']:
                    print(json.dumps([{'Name':'woow-tailscale-gateway-state','Labels':{**labels,'org.woow-tailscale.role':'state'}}]));raise SystemExit(0)
                if a and a[0]=='exec':
                    print(json.dumps({'Self':{'ID':open(identity).read().strip()}}));raise SystemExit(0)
                if a[:2]==['volume','export']:
                    open(a[a.index('--output')+1],'wb').write(b'rollback');raise SystemExit(0)
                if a[:2]==['volume','import']:
                    open(identity,'w').write('new-self' if a[-1].endswith('/state.tar') else 'old-self');raise SystemExit(0)
                if a[:2] in (['volume','rm'],['volume','create']): raise SystemExit(0)
                raise SystemExit(2)
            """)
            archive_dir = Path(d) / "archive"; archive_dir.mkdir()
            (archive_dir / "state.tar").write_bytes(b"restored")
            labels = {"org.woow-tailscale.project": "woow-tailscale-gateway", "org.woow-tailscale.role": "state", "org.woow-tailscale.managed-by": "woow-gateway-lifecycle", "org.woow-tailscale.checkout": str(checkout)}
            (archive_dir / "manifest.json").write_text(json.dumps({"schema": 2, "checkout": str(checkout), "self_id": "new-self", "volume": "woow-tailscale-gateway-state", "volume_labels": labels}))
            subprocess.run("sha256sum manifest.json state.tar >SHA256SUMS", cwd=archive_dir, shell=True, check=True)
            archive = Path(d) / "restore.tar"
            subprocess.run(["tar", "-C", str(archive_dir), "-cf", str(archive), "manifest.json", "SHA256SUMS", "state.tar"], check=True)
            env = {"CHECKOUT": str(checkout), "IDENTITY": str(identity), "VERIFY_COUNT": str(verify_count), "XDG_RUNTIME_DIR": d}
            rolled_back = self.run_with_path(["bash", "scripts/restore.sh", str(archive), "--confirm-restore"], d, cwd=checkout, env=env)
            self.assertNotEqual(rolled_back.returncode, 0)
            self.assertIn("exact Self.ID were rolled back and verified", rolled_back.stderr)
            self.assertEqual(identity.read_text(), "old-self")
            verify_count.unlink(missing_ok=True); identity.write_text("old-self")
            retained = self.run_with_path(["bash", "scripts/restore.sh", str(archive), "--confirm-restore"], d, cwd=checkout, env={**env, "FAIL_ROLLBACK_VERIFY": "1"})
            self.assertNotEqual(retained.returncode, 0)
            marker = "protected rollback archive retained at "
            self.assertIn(marker, retained.stderr)
            retained_path = Path(retained.stderr.split(marker, 1)[1].splitlines()[0])
            self.assertTrue(retained_path.is_file())
            retained_path.unlink()

    def test_health_rejects_extra_serve_namespace(self):
        with tempfile.TemporaryDirectory() as d:
            self.make_command(d, "tailscale", textwrap.dedent("""#!/usr/bin/env python3
                import os,sys
                if sys.argv[1:3]==['status','--json']: print('{"BackendState":"Running"}')
                elif sys.argv[1:4]==['serve','status','--json']: print(os.environ['SERVE_JSON'])
                else: raise SystemExit(2)
            """))
            self.make_command(d, "timeout", "#!/bin/sh\nexit 0\n")
            base = {"TCP": {"18081": {"TCPForward": "127.0.0.1:18081"}, "18069": {"TCPForward": "127.0.0.1:18069"}}, "Web": {}}
            good = self.run_with_path(["bash", "scripts/container-health.sh"], d, env={"SERVE_JSON": json.dumps(base)})
            base["Funnel"] = {"18081": True}
            bad = self.run_with_path(["bash", "scripts/container-health.sh"], d, env={"SERVE_JSON": json.dumps(base)})
            self.assertEqual(good.returncode, 0)
            self.assertNotEqual(bad.returncode, 0)


if __name__ == "__main__":
    unittest.main()
