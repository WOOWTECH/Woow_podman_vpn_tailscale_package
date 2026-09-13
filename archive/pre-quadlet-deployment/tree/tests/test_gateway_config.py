import os, stat, subprocess, tempfile, unittest
from pathlib import Path
from scripts.gateway_config import parse, runtime

VALID = """GATEWAY_HOSTNAME=woow-service-gateway
HEADSCALE_URL=http://127.0.0.1:28080
HEADSCALE_CONTAINER=headscale
HEADSCALE_USER=default
STATE_VOLUME=woow-tailscale-gateway-state
"""
class ConfigTests(unittest.TestCase):
    def file(self, text=VALID):
        d=tempfile.TemporaryDirectory(); p=Path(d.name)/"env"; p.write_text(text); self.addCleanup(d.cleanup); return p
    def test_fixed_runtime(self):
        c=runtime(parse(self.file()))
        self.assertEqual(c["TS_USERSPACE_NETWORKING"],"true"); self.assertEqual(c["TS_WEB_UI"],"false")
        self.assertEqual(c["TS_SERVE_TCP_18081"],"127.0.0.1:18081"); self.assertEqual(c["TS_SERVE_TCP_18069"],"127.0.0.1:18069")
        self.assertNotIn("AUTH", "".join(c))
    def test_rejects_malformed(self):
        bad=[VALID+"BOGUS=x\n", VALID+"HEADSCALE_USER=default\n", VALID.replace("default","other"), VALID.replace("http://","ftp://"), VALID.replace("127.0.0.1:28080","u:p@host"), VALID.replace("woow-service-gateway","bad_name"), VALID.replace("default","$USER"), VALID.replace("woow-service-gateway","$(id)"), VALID.replace("woow-service-gateway","`id`"), VALID.replace("default",""), VALID.replace("\n","\r\n")]
        for text in bad:
            with self.subTest(text=text):
                with self.assertRaises(ValueError): parse(self.file(text))
    def test_render_permissions_and_ignores_environment(self):
        p=self.file(); out=p.parent/"runtime"/"gateway.env"
        env={**os.environ,"HEADSCALE_USER":"attacker","TS_WEB_UI":"true"}
        subprocess.run(["python3","scripts/gateway_config.py","render",str(p),str(out)],check=True,env=env)
        self.assertEqual(stat.S_IMODE(out.parent.stat().st_mode),0o700); self.assertEqual(stat.S_IMODE(out.stat().st_mode),0o600)
        self.assertIn("TS_WEB_UI=false",out.read_text()); self.assertNotIn("auth",out.read_text().lower())
if __name__ == '__main__': unittest.main()
