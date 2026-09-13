import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
S=Path('entrypoint.sh').read_text()
class EntrypointContract(unittest.TestCase):
 def test_userspace_and_file_secret(self):
  self.assertIn('--tun=userspace-networking',S); self.assertIn('--authkey="file:$TS_AUTHKEY_FILE"',S)
  self.assertIn('stat -c %a',S); self.assertIn('! -L "$TS_AUTHKEY_FILE"',S); self.assertIn('/run/secrets/headscale-preauth.key',S)
  self.assertIn('gateway enrollment never accepts an auth key value',S)
 def test_exact_serve_reconciliation(self):
  a=S.index('tailscale serve reset'); b=S.index('tailscale serve --bg --tcp=18081 tcp://127.0.0.1:18081'); c=S.index('tailscale serve --bg --tcp=18069 tcp://127.0.0.1:18069')
  self.assertLess(a,b); self.assertLess(b,c); self.assertIn("'.BackendState // empty'",S)
 def test_fail_closed_and_redacted(self):
  self.assertIn('mutually exclusive',S); self.assertIn('--authkey=<redacted>',S)
  self.assertNotIn('eval ',S); self.assertIn('gateway route environment flags must be omitted',S)
 def test_gateway_serve_commands_execute_in_order_and_fail_closed(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory); fake=root/'bin'; fake.mkdir(); log=root/'commands'; state=root/'state'
   tailscaled=fake/'tailscaled'; tailscaled.write_text(textwrap.dedent(f'''#!/usr/bin/env python3
import socket,sys,time
p=next(x.split('=',1)[1] for x in sys.argv[1:] if x.startswith('--socket='))
s=socket.socket(socket.AF_UNIX);s.bind(p);time.sleep(.4);s.close()
''')); tailscaled.chmod(0o755)
   tailscale=fake/'tailscale'; tailscale.write_text(textwrap.dedent('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['COMMAND_LOG'],'a') as f:f.write('tailscale '+' '.join(sys.argv[1:])+'\\n')
a=sys.argv[1:]
if a[:2]==['status','--json']: print(json.dumps({'BackendState':'Running','CurrentTailnet':{}}))
if a[:3]==['serve','--bg','--tcp=18081'] and os.environ.get('FAIL_SERVE')=='1': raise SystemExit(7)
''')); tailscale.chmod(0o755)
   run_dir=root/'run'
   env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'COMMAND_LOG':str(log),'STATE_DIR':str(state),'WOOW_ENTRYPOINT_TESTING':'true','WOOW_TAILSCALE_TEST_RUN_DIR':str(run_dir),'TS_GATEWAY_MODE':'true','TS_USERSPACE_NETWORKING':'true','TS_WEB_UI':'false','TS_ACCEPT_DNS':'true','TS_ADVERTISE_CONNECTOR':'false','TS_ALWAYS_USE_DERP':'false','TS_SERVE_TCP_18081':'127.0.0.1:18081','TS_SERVE_TCP_18069':'127.0.0.1:18069'}
   socket=run_dir/'tailscaled.sock'
   result=subprocess.run(['bash','entrypoint.sh'],text=True,capture_output=True,env=env)
   commands=log.read_text().splitlines(); self.assertEqual(result.returncode,0,result.stderr)
   self.assertLess(next(i for i,x in enumerate(commands) if x.startswith('tailscale up ')),commands.index('tailscale serve reset'))
   self.assertLess(commands.index('tailscale serve reset'),commands.index('tailscale serve --bg --tcp=18081 tcp://127.0.0.1:18081'))
   self.assertLess(commands.index('tailscale serve --bg --tcp=18081 tcp://127.0.0.1:18081'),commands.index('tailscale serve --bg --tcp=18069 tcp://127.0.0.1:18069'))
   socket.unlink(missing_ok=True); log.unlink()
   failed=subprocess.run(['bash','entrypoint.sh'],text=True,capture_output=True,env={**env,'FAIL_SERVE':'1'})
   self.assertNotEqual(failed.returncode,0); self.assertNotIn('--tcp=18069',log.read_text())
   socket.unlink(missing_ok=True)
 def test_runtime_override_requires_explicit_test_mode(self):
  with tempfile.TemporaryDirectory() as directory:
   result=subprocess.run(['bash','entrypoint.sh'],text=True,capture_output=True,env={**os.environ,'WOOW_TAILSCALE_TEST_RUN_DIR':directory})
   self.assertEqual(result.returncode,2); self.assertIn('forbidden in production',result.stderr)
 def test_image_has_curl(self): self.assertIn('curl',Path('Containerfile').read_text())
if __name__=='__main__': unittest.main()
