import json, os, shutil, stat, subprocess, tempfile, textwrap, unittest
from pathlib import Path
from scripts.image_id import normalize_image_id
from scripts.gateway_unit import image_from_unit, rendered
ROOT=Path(__file__).resolve().parents[1]
S=(ROOT/'scripts/deploy.sh').read_text()
class DeployContract(unittest.TestCase):
 def test_order_and_key_security(self):
  self.assertLess(S.index('gateway_config.py render'),S.index('volume create'))
  self.assertIn('--expiration 5m --output json >"$response"',S); self.assertIn('--reusable',S)
  self.assertIn('TS_AUTHKEY_FILE=/run/secrets/headscale-preauth.key',S); self.assertNotIn('--env TS_AUTHKEY=',S); self.assertNotIn('set -x',S)
  self.assertIn(': >"$f"; rm -f "$f"',S); self.assertIn('preauthkeys expire --id',S); self.assertIn('preauthkeys delete --id',S)
  self.assertIn('assert-preauth-id-absent',S); self.assertIn('failed to delete enrollment key',S)
  self.assertIn('headscale --force nodes delete --identifier "$enrolled_node_id"',S)
  self.assertNotIn('headscale nodes delete --identifier',S)
  self.assertIn('refusing to replace a foreign gateway image tag',S); self.assertIn('persistent gateway identity is valid but verification failed; refusing re-enrollment',S)
  self.assertEqual(S.count('.Labels["org.woow-tailscale.invocation"]'),1)
 def test_steady_unit_has_no_secret(self):
  unit=Path('systemd/woow-tailscale-gateway.service.in').read_text(); self.assertNotIn('AUTHKEY',unit); self.assertNotIn('/run/secrets',unit)
 def test_image_id_normalization_is_full_lowercase_hex_only(self):
  bare='0123456789abcdef'*4
  self.assertEqual(normalize_image_id(bare),bare)
  self.assertEqual(normalize_image_id('sha256:'+bare),bare)
  for invalid in (bare[:-1],bare+'0','sha256:'+bare[:-1],'sha256:sha256:'+bare,'g'+bare[1:],bare.upper(),'sha512:'+bare,'repo@example@sha256:'+bare):
   with self.subTest(invalid=invalid), self.assertRaises(ValueError): normalize_image_id(invalid)
 def test_unit_render_canonicalizes_prefixed_id_and_checks_old_exact_unit(self):
  bare='abcdef0123456789'*4; template=ROOT/'systemd/woow-tailscale-gateway.service.in'
  with tempfile.TemporaryDirectory() as directory:
   old=Path(directory)/'old.service'
   old.write_text(template.read_text().replace('@CHECKOUT@',str(ROOT)).replace('@IMAGE@','sha256:'+bare))
   self.assertEqual(image_from_unit(old),'sha256:'+bare)
   self.assertIn(' '+bare+'\n',rendered(template,str(ROOT),'sha256:'+bare))
   self.assertNotIn('sha256:'+bare,rendered(template,str(ROOT),'sha256:'+bare))
   checked=subprocess.run(['python3','scripts/gateway_unit.py','check',str(old),str(template),str(ROOT)],text=True,capture_output=True)
   self.assertEqual(checked.returncode,0,checked.stderr); self.assertEqual(checked.stdout.strip(),bare)
 def test_fake_deploy_orders_enrollment_cleans_failure_and_is_idempotent(self):
  def fixture(directory):
   root=Path(directory)/'checkout'; (root/'scripts').mkdir(parents=True); (root/'systemd').mkdir(); (root/'runtime').mkdir(mode=0o700)
   shutil.copy2('scripts/deploy.sh',root/'scripts/deploy.sh'); shutil.copy2('scripts/gateway_unit.py',root/'scripts/gateway_unit.py'); shutil.copy2('scripts/image_id.py',root/'scripts/image_id.py'); shutil.copy2('systemd/woow-tailscale-gateway.service.in',root/'systemd/woow-tailscale-gateway.service.in'); (root/'Containerfile').write_text('FROM scratch\n')
   (root/'.env.gateway').write_text('stub\n'); (root/'.env.gateway').chmod(0o600)
   stubs={
    'gateway_config.py':'''#!/usr/bin/env python3
import json,os,sys
if sys.argv[1]=='render':
 os.makedirs(os.path.dirname(sys.argv[3]),exist_ok=True);open(sys.argv[3],'w').write('TS_GATEWAY_MODE=true\\n');os.chmod(sys.argv[3],0o600)
else: print(json.dumps({'HEADSCALE_CONTAINER':'headscale','GATEWAY_HOSTNAME':'gateway'}))
''',
    'resource_ownership.py':(ROOT/'scripts/resource_ownership.py').read_text(),
    'headscale_json.py':'''#!/usr/bin/env python3
import os,sys
if sys.argv[1]=='default-user-id': print('1')
elif sys.argv[1]=='extract-preauth':
 open(sys.argv[3],'w').write('7\\n');open(sys.argv[4],'w').write('opaque\\n');os.chmod(sys.argv[3],0o600);os.chmod(sys.argv[4],0o600)
elif sys.argv[1]=='find-node': print('9')
''',
    'verify.sh':'#!/bin/sh\nprintf "verify\\n" >>"$COMMAND_LOG"\n[ "${FAIL_VERIFY:-0}" != 1 ]\n'}
   for name,body in stubs.items(): p=root/'scripts'/name;p.write_text(body);p.chmod(0o755)
   fake=Path(directory)/'bin'; fake.mkdir(); state=Path(directory)/'state.json'; state.write_text(json.dumps({'volume':False,'image':False,'container':False,'image_generation':0})); mount=Path(directory)/'volume'; log=Path(directory)/'commands'
   podman=fake/'podman'; podman.write_text(textwrap.dedent('''#!/usr/bin/env python3
import json,os,sys
p=os.environ['FAKE_STATE'];s=json.load(open(p));a=sys.argv[1:];root=os.environ['CHECKOUT'];mount=os.environ['VOLUME_MOUNT']
def save(): open(p,'w').write(json.dumps(s))
def record():
 with open(os.environ['COMMAND_LOG'],'a') as f:f.write('podman '+' '.join(a)+'\\n')
record(); labels={'org.woow-tailscale.project':'woow-tailscale-gateway','org.woow-tailscale.managed-by':'woow-gateway-lifecycle','org.woow-tailscale.checkout':root}
if a[:2]==['inspect','-f']: print('true');raise SystemExit(0)
if a[:2]==['image','inspect']:
 if not s['image']: print('not found',file=sys.stderr);raise SystemExit(1)
 bare_id=format(s['image_generation'],'064x')
 image_id=os.environ.get('IMAGE_ID_OVERRIDE') or (('sha256:' if os.environ.get('PREFIX_IMAGE_ID')=='1' else '')+bare_id)
 if '--format' in a: print(image_id)
 else: print(json.dumps([{'Id':image_id,'Digest':'sha256:'+('f'*64),'Labels':{**labels,'org.woow-tailscale.role':'image'}}]))
 raise SystemExit(0)
if a[:2]==['volume','inspect']:
 if not s['volume']: print('not found',file=sys.stderr);raise SystemExit(1)
 if '--format' in a: print(mount)
 else: print(json.dumps([{'Name':'woow-tailscale-gateway-state','Labels':{**labels,'org.woow-tailscale.role':'state',**({'org.woow-tailscale.invocation':s['volume_invocation']} if s.get('volume_invocation') else {})}}]))
 raise SystemExit(0)
if a[:2]==['volume','create']:
 os.makedirs(mount,exist_ok=True);s['volume']=True;s['volume_invocation']=next(x.split('=',1)[1] for x in a if x.startswith('org.woow-tailscale.invocation='));save();print(a[-1]);raise SystemExit(0)
if a[:2]==['volume','rm']: s['volume']=False;save();raise SystemExit(0)
if a and a[0]=='build': s['image']=True;s['image_generation']+=1;save();raise SystemExit(0)
if a and a[0]=='run':
 if os.environ.get('FAIL_RUN')=='1': raise SystemExit(8)
 volumes=[a[i+1] for i,x in enumerate(a) if x=='--volume']
 secret=next(x for x in volumes if x.endswith(':/run/secrets/headscale-preauth.key:ro'))
 s['container']=True;s['container_invocation']=next(x.split('=',1)[1] for x in a if x.startswith('org.woow-tailscale.invocation='));s['secret_source']=secret.rsplit(':/run/secrets/headscale-preauth.key:ro',1)[0];s['container_image']=a[-1];save();open(os.path.join(mount,'tailscaled.state'),'w').write('state');print('cid');raise SystemExit(0)
if a[:2]==['container','inspect']:
 if not s['container']: print('not found',file=sys.stderr);raise SystemExit(1)
 container_image=('sha256:' if os.environ.get('PREFIX_CONTAINER_IMAGE')=='1' else '')+s['container_image']
 if '--format' in a: print(container_image);raise SystemExit(0)
 mounts=[{'Type':'volume','Name':'woow-tailscale-gateway-state','Source':mount,'Destination':'/var/lib/tailscale','RW':True}]
 if s.get('secret_source'): mounts.append({'Type':'bind','Source':s['secret_source'],'Destination':'/run/secrets/headscale-preauth.key','RW':False})
 container_labels={**labels,'org.woow-tailscale.role':'gateway',**({'org.woow-tailscale.invocation':s['container_invocation']} if s.get('container_invocation') else {})}
 obj={'Name':'/woow-tailscale-gateway','Image':container_image,'State':{'Running':True},'HostConfig':{'NetworkMode':'host','PortBindings':{},'CapAdd':[],'Devices':[]},'Config':{'Env':['TS_GATEWAY_MODE=true']},'Mounts':mounts}
 if os.environ.get('INSPECT_LABEL_LOCATION')=='config': obj['Config']['Labels']=container_labels
 else: obj['Labels']=container_labels
 print(json.dumps([obj]));raise SystemExit(0)
if a[:2]==['rm','-f']: s['container']=False;s.pop('secret_source',None);save();raise SystemExit(0)
if a and a[0]=='healthcheck': raise SystemExit(0)
if a and a[0]=='exec':
 if a[1]=='headscale':
  if a[2:4]==['headscale','version']: print('headscale v0.29.3')
  elif 'users' in a: print('[{"id":1,"name":"default"}]')
  elif 'preauthkeys' in a and 'create' in a:
   print('{"id":7,"key":"opaque"}')
   if os.environ.get('FAIL_KEY_CREATE')=='1': raise SystemExit(8)
  elif 'preauthkeys' in a and 'list' in a: print('[{"id":99,"reusable":true,"expiration":"2999-01-01T00:00:00Z"}]')
  elif 'nodes' in a:
   if os.environ.get('FAIL_NODES_LIST')=='1': raise SystemExit(8)
   print('[{"id":9,"given_name":"gateway","ip_addresses":["100.64.0.1"]}]')
 else: print('{"BackendState":"Running","Self":{"ID":"self-1","HostName":"gateway","TailscaleIPs":["100.64.0.1"]}}')
 raise SystemExit(0)
raise SystemExit(2)
''')); podman.chmod(0o755)
   systemctl=fake/'systemctl'; systemctl.write_text(textwrap.dedent('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['COMMAND_LOG'],'a') as f:f.write('systemctl '+' '.join(sys.argv[1:])+'\\n')
p=os.environ['FAKE_STATE'];s=json.load(open(p))
if 'is-active' in sys.argv: raise SystemExit(0 if s['container'] else 3)
if 'enable' in sys.argv or 'restart' in sys.argv:
 s['container']=True;s['container_image']=format(s['image_generation'],'064x');s.pop('secret_source',None);s.pop('container_invocation',None);open(p,'w').write(json.dumps(s))
if 'stop' in sys.argv:
 p=os.environ['FAKE_STATE'];s=json.load(open(p));s['container']=False;open(p,'w').write(json.dumps(s))
''')); systemctl.chmod(0o755)
   timeout=fake/'timeout'; timeout.write_text('#!/bin/sh\n[ "$1" = 3 ] && exit 0\nshift\nexec "$@"\n'); timeout.chmod(0o755)
   sleep=fake/'sleep'; sleep.write_text('#!/bin/sh\nexit 0\n'); sleep.chmod(0o755)
   curl=fake/'curl'; curl.write_text('#!/bin/sh\nexit 0\n'); curl.chmod(0o755)
   return root,fake,state,mount,log
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root),'INSPECT_LABEL_LOCATION':'config'}
   first=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertEqual(first.returncode,0,first.stderr)
   commands=log.read_text(); self.assertLess(commands.index('podman volume create'),commands.index('podman build')); self.assertLess(commands.index('preauthkeys create'),commands.index('podman run -d')); self.assertLess(commands.index('preauthkeys delete'),commands.index('systemctl --user enable --now'))
   create_count=commands.count('preauthkeys create')
   second=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertEqual(second.returncode,0,second.stderr); all_commands=log.read_text(); self.assertEqual(all_commands.count('preauthkeys create'),create_count); self.assertIn('persistent state',second.stdout)
   self.assertIn('systemctl --user restart woow-tailscale-gateway.service',all_commands)
   deployed=json.loads(state.read_text()); expected=format(deployed['image_generation'],'064x'); self.assertEqual(deployed['container_image'],expected); self.assertIn(expected,(Path(env['HOME'])/'.config/systemd/user/woow-tailscale-gateway.service').read_text()); self.assertNotIn('sha256:'+expected,(Path(env['HOME'])/'.config/systemd/user/woow-tailscale-gateway.service').read_text())
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root),'PREFIX_IMAGE_ID':'1','PREFIX_CONTAINER_IMAGE':'1'}
   compatible=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertEqual(compatible.returncode,0,compatible.stderr)
   expected=format(json.loads(state.read_text())['image_generation'],'064x'); unit=(Path(env['HOME'])/'.config/systemd/user/woow-tailscale-gateway.service').read_text(); self.assertIn(' '+expected+'\n',unit); self.assertNotIn('sha256:'+expected,unit)
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); invalid='a'*63; env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root),'IMAGE_ID_OVERRIDE':invalid}
   rejected=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertNotEqual(rejected.returncode,0); self.assertIn('no unambiguous full sha256 ID',rejected.stderr); self.assertNotIn('preauthkeys create',log.read_text())
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root),'FAIL_RUN':'1'}
   failed=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertNotEqual(failed.returncode,0); commands=log.read_text(); self.assertIn('preauthkeys expire',commands); self.assertIn('preauthkeys delete',commands); self.assertIn('podman volume rm',commands); self.assertFalse(json.loads(state.read_text())['volume'])
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root),'FAIL_NODES_LIST':'1','INSPECT_LABEL_LOCATION':'config'}
   failed=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertNotEqual(failed.returncode,0); commands=log.read_text(); self.assertIn('podman rm -f woow-tailscale-gateway',commands); cleaned=json.loads(state.read_text()); self.assertFalse(cleaned['container']); self.assertFalse(cleaned['volume'])
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root),'FAIL_KEY_CREATE':'1'}
   failed=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertNotEqual(failed.returncode,0); commands=log.read_text(); self.assertIn('preauthkeys expire --id 7',commands); self.assertIn('preauthkeys delete --id 7',commands); self.assertIn('preauthkeys list --output json',commands)
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); mount.mkdir(); state.write_text(json.dumps({'volume':True,'image':False,'container':False,'image_generation':0}))
   env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root)}
   recovered=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertEqual(recovered.returncode,0,recovered.stderr); commands=log.read_text(); self.assertIn('preauthkeys create',commands); self.assertNotIn('podman volume create',commands)
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); mount.mkdir(); state.write_text(json.dumps({'volume':True,'image':False,'container':False,'image_generation':0}))
   env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root),'FAIL_VERIFY':'1'}
   failed=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertNotEqual(failed.returncode,0); self.assertTrue(mount.is_dir()); self.assertEqual(list(mount.iterdir()),[])
   self.assertIn('headscale --force nodes delete --identifier 9',log.read_text())
   for record in ('gateway-self-id','gateway-node-id','gateway-enrollment-id'): self.assertFalse((root/'runtime'/record).exists())
   retry=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env={k:v for k,v in env.items() if k!='FAIL_VERIFY'})
   self.assertEqual(retry.returncode,0,retry.stderr); self.assertEqual(log.read_text().count('preauthkeys create'),2)
  with tempfile.TemporaryDirectory() as directory:
   root,fake,state,mount,log=fixture(directory); unit=Path(directory)/'home/.config/systemd/user/woow-tailscale-gateway.service'; unit.parent.mkdir(parents=True); unit.write_text('[Service]\nExecStart=/bin/false\n')
   env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'HOME':str(Path(directory)/'home'),'XDG_RUNTIME_DIR':directory,'FAKE_STATE':str(state),'VOLUME_MOUNT':str(mount),'COMMAND_LOG':str(log),'CHECKOUT':str(root)}
   refused=subprocess.run(['bash','scripts/deploy.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertNotEqual(refused.returncode,0); self.assertIn('foreign gateway unit',refused.stderr); self.assertNotIn('podman build',log.read_text())
 def test_resource_ownership_enrollment_inspect_contract(self):
  with tempfile.TemporaryDirectory() as directory:
   directory=Path(directory); keyfile=directory/'enrollment.key'; keyfile.write_text('opaque\n'); keyfile.chmod(0o600)
   inspect_file=directory/'inspect.json'; fake=directory/'bin'; fake.mkdir()
   podman=fake/'podman'; podman.write_text(textwrap.dedent('''#!/usr/bin/env python3
import os,sys
if sys.argv[1:3]==['container','inspect']:
 print(open(os.environ['INSPECT_FILE']).read());raise SystemExit(0)
raise SystemExit(2)
''')); podman.chmod(0o755)
   labels={'org.woow-tailscale.project':'woow-tailscale-gateway','org.woow-tailscale.role':'gateway','org.woow-tailscale.managed-by':'woow-gateway-lifecycle','org.woow-tailscale.checkout':str(ROOT),'org.woow-tailscale.invocation':'inv-1'}
   state_mount={'Type':'volume','Name':'woow-tailscale-gateway-state','Destination':'/var/lib/tailscale','RW':True}
   secret_mount={'Type':'bind','Source':str(keyfile),'Destination':'/run/secrets/headscale-preauth.key','RW':False}
   def check(mounts, enrollment=True, fixture_labels=None):
    obj={'Name':'/woow-tailscale-gateway','Labels':fixture_labels or labels,'Mounts':mounts,'State':{'Running':True}}
    inspect_file.write_text(json.dumps([obj]))
    args=['python3','scripts/resource_ownership.py','check-container',str(ROOT)]
    if enrollment: args += ['--enrollment-keyfile',str(keyfile),'--invocation','inv-1']
    return subprocess.run(args,text=True,capture_output=True,env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'INSPECT_FILE':str(inspect_file)})
   self.assertEqual(check([state_mount,secret_mount]).returncode,0)
   config_obj={'Name':'/woow-tailscale-gateway','Config':{'Labels':labels},'Mounts':[state_mount,secret_mount],'State':{'Running':True}}
   inspect_file.write_text(json.dumps([config_obj]))
   config_result=subprocess.run(['python3','scripts/resource_ownership.py','check-container',str(ROOT),'--enrollment-keyfile',str(keyfile),'--invocation','inv-1'],text=True,capture_output=True,env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'INSPECT_FILE':str(inspect_file)})
   self.assertEqual(config_result.returncode,0,config_result.stderr)
   self.assertNotEqual(check([state_mount,secret_mount],enrollment=False).returncode,0)
   self.assertNotEqual(check([state_mount,{**secret_mount,'Source':str(directory/'foreign.key')}]).returncode,0)
   self.assertNotEqual(check([state_mount,{**secret_mount,'RW':True}]).returncode,0)
   self.assertNotEqual(check([state_mount,secret_mount,{**secret_mount,'Source':'/foreign','Destination':'/run/secrets/extra'}]).returncode,0)
   self.assertNotEqual(check([state_mount,{'Type':'bind','Source':'/foreign','Destination':'/run/secrets','RW':False}],enrollment=False).returncode,0)
   self.assertNotEqual(check([state_mount,secret_mount],fixture_labels={**labels,'org.woow-tailscale.invocation':'other'}).returncode,0)
   keyfile.chmod(0o644); self.assertNotEqual(check([state_mount,secret_mount]).returncode,0)
 def test_json_helper_never_prints_key(self):
  with tempfile.TemporaryDirectory() as d:
   src=Path(d)/'r'; ident=Path(d)/'id'; key=Path(d)/'key'; src.write_text(json.dumps({'id':7,'key':'SECRET_BYTES'}))
   p=subprocess.run(['python3','scripts/headscale_json.py','extract-preauth',str(src),str(ident),str(key)],text=True,capture_output=True)
   self.assertEqual(p.returncode,0); self.assertEqual(p.stdout+p.stderr,''); self.assertEqual(key.read_text().strip(),'SECRET_BYTES'); self.assertEqual(stat.S_IMODE(key.stat().st_mode),0o600)
if __name__=='__main__': unittest.main()
