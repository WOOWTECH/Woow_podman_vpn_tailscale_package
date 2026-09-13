import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from scripts import live_cleanup

S=Path('scripts/live-test.sh').read_text()
FIXTURES=Path('tests/fixtures/cli')
class LiveContract(unittest.TestCase):
 def test_sequence_and_isolation(self):
  self.assertLess(S.index('scripts/verify.sh'),S.index('podman network create'))
  for x in ('uuid.uuid4','--tun=userspace-networking','--socks5-server=0.0.0.0:1055','--authkey=file:/run/secrets/live-preauth.key','ping --peerapi --timeout=5s "$gateway_ip"','socks5h://$client:1055','--entrypoint curl "$curl_image"'): self.assertIn(x,S)
  self.assertNotIn('--type=peerapi',S)
  self.assertIn("! grep -qi 'DERP'",S); self.assertIn("grep -Eq 'via [^ ]+:[0-9]+'",S)
  self.assertNotIn('curlimages/curl',S); self.assertIn('curl_image="$image_id"',S)
 def test_observed_1_102_and_0_29_3_cli_fixtures(self):
  tailscale_help=(FIXTURES/'tailscale-1.102.0-ping-help.txt').read_text()
  headscale_help=(FIXTURES/'headscale-0.29.3-force-help.txt').read_text()
  failures=json.loads((FIXTURES/'observed-cleanup-failures.json').read_text())
  self.assertIn('--peerapi',tailscale_help); self.assertIn('There is no --type flag',tailscale_help)
  self.assertIn('global Headscale flag',headscale_help)
  self.assertEqual(failures['tailscale_type_peerapi']['returncode'],1)
  self.assertTrue(failures['headscale_without_global_force']['node_present_after'])
  self.assertTrue(failures['podman_network_without_force']['network_present_after'])
 def test_cleanup_and_separate_key(self):
  self.assertLess(S.index('trap cleanup EXIT'),S.index('podman network create'))
  for x in ('preauthkeys expire','preauthkeys delete','live_cleanup.py','--node-hostname',': >"$keyfile"'): self.assertIn(x,S)
  self.assertNotIn('woow-tailscale-gateway-state:/var/lib/tailscale',S)
 def test_runtime_file_validation_rejects_relative_symlink_and_bad_mode(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory); runtime=root/'runtime'; runtime.mkdir(mode=0o700)
   key=runtime/'key'; key.write_text('opaque\n'); key.chmod(0o600)
   command=['python3',str(Path.cwd()/'scripts/runtime_file.py')]
   valid=subprocess.run([*command,str(runtime),str(key)],text=True,capture_output=True)
   relative=subprocess.run([*command,'runtime','runtime/key'],cwd=root,text=True,capture_output=True)
   link=runtime/'link'; link.symlink_to(key)
   symlink=subprocess.run([*command,str(runtime),str(link)],text=True,capture_output=True)
   key.chmod(0o640)
   bad_mode=subprocess.run([*command,str(runtime),str(key)],text=True,capture_output=True)
   self.assertEqual(valid.returncode,0,valid.stderr)
   self.assertNotEqual(relative.returncode,0)
   self.assertNotEqual(symlink.returncode,0)
   self.assertNotEqual(bad_mode.returncode,0)
 def test_podman_49_absent_error_fixtures_are_narrow(self):
  fixtures=(
   ('container','Error: no such container live-client'),
   ('volume','Error: volume live-state not found'),
   ('network','Error: unable to find network live-net'),
   ('network','Error: unable to find network with name or ID live-net'),
  )
  for kind,error in fixtures:
   with self.subTest(error=error): self.assertTrue(live_cleanup.absent_inspect_error(kind,error))
  for error in ('Error: permission denied','Error: unable to find helper binary','unexpected transport failure'):
   with self.subTest(error=error): self.assertFalse(live_cleanup.absent_inspect_error('network',error))
 def test_podman_49_raw_network_inspect_lowercase_labels(self):
  raw=(FIXTURES/'podman-4.9.3-network-inspect.json').read_text()
  observed=json.loads(raw)[0]
  result=SimpleNamespace(returncode=0,stdout=raw,stderr='')
  with patch.object(live_cleanup,'command',return_value=result) as command:
   inspected=live_cleanup.inspect_owned('network','live-net','inv-1')
  self.assertEqual(inspected,observed)
  command.assert_called_once_with(['podman','network','inspect','live-net'])
 def test_network_inspect_uppercase_labels_remain_compatible(self):
  observed=json.loads((FIXTURES/'podman-4.9.3-network-inspect.json').read_text())[0]
  result=SimpleNamespace(returncode=0,stdout=json.dumps([{'Labels':observed['labels']}]),stderr='')
  with patch.object(live_cleanup,'command',return_value=result):
   self.assertIsNotNone(live_cleanup.inspect_owned('network','live-net','inv-1'))
 def test_lowercase_labels_are_network_only_schema_fallback(self):
  observed=json.loads((FIXTURES/'podman-4.9.3-network-inspect.json').read_text())[0]
  result=SimpleNamespace(returncode=0,stdout=json.dumps([observed]),stderr='')
  with patch.object(live_cleanup,'command',return_value=result):
   with self.assertRaises(live_cleanup.ForeignResourceError):
    live_cleanup.inspect_owned('container','live-net','inv-1')
  conflicting={**observed,'Labels':{**observed['labels'],'org.woow-tailscale.invocation':'foreign'}}
  result=SimpleNamespace(returncode=0,stdout=json.dumps([conflicting]),stderr='')
  with patch.object(live_cleanup,'command',return_value=result):
   with self.assertRaises(live_cleanup.ForeignResourceError):
    live_cleanup.inspect_owned('network','live-net','inv-1')
 def test_lowercase_network_labels_require_every_exact_label(self):
  observed=json.loads((FIXTURES/'podman-4.9.3-network-inspect.json').read_text())[0]
  for key in observed['labels']:
   for mutation in ('missing','wrong'):
    with self.subTest(key=key,mutation=mutation):
     labels=dict(observed['labels'])
     if mutation=='missing': labels.pop(key)
     else: labels[key]='foreign'
     result=SimpleNamespace(returncode=0,stdout=json.dumps([{**observed,'labels':labels}]),stderr='')
     with patch.object(live_cleanup,'command',return_value=result):
      with self.assertRaises(live_cleanup.ForeignResourceError):
       live_cleanup.inspect_owned('network','live-net','inv-1')
 def test_network_cleanup_removes_then_accepts_observed_absence(self):
  labels={
   'org.woow-tailscale.project':'woow-tailscale-gateway',
   'org.woow-tailscale.role':'live-test',
   'org.woow-tailscale.managed-by':'woow-gateway-lifecycle',
   'org.woow-tailscale.invocation':'inv-1',
  }
  present=SimpleNamespace(returncode=0,stdout=json.dumps([{'Labels':labels}]),stderr='')
  removed=SimpleNamespace(returncode=0,stdout='',stderr='')
  absent=SimpleNamespace(returncode=1,stdout='',stderr='Error: unable to find network live-net')
  errors=[]
  with patch.object(live_cleanup,'command',side_effect=[present,removed,absent]) as command:
   live_cleanup.remove_owned('network','live-net','inv-1',errors,'test network')
  self.assertEqual(errors,[])
  self.assertEqual(command.call_args_list[1].args[0],['podman','network','rm','-f','live-net'])
  with patch.object(live_cleanup,'command',return_value=absent) as command:
   live_cleanup.remove_owned('network','live-net','inv-1',errors,'test network')
  command.assert_called_once_with(['podman','network','inspect','live-net'])
  self.assertEqual(errors,[])
 def test_network_cleanup_retries_only_transient_in_use_failures(self):
  labels={
   'org.woow-tailscale.project':'woow-tailscale-gateway',
   'org.woow-tailscale.role':'live-test',
   'org.woow-tailscale.managed-by':'woow-gateway-lifecycle',
   'org.woow-tailscale.invocation':'inv-1',
  }
  present=SimpleNamespace(returncode=0,stdout=json.dumps([{'Labels':labels}]),stderr='')
  in_use=SimpleNamespace(returncode=2,stdout='',stderr='Error: network live-net is being used by container cleanup-race')
  removed=SimpleNamespace(returncode=0,stdout='',stderr='')
  absent=SimpleNamespace(returncode=1,stdout='',stderr='Error: unable to find network live-net')
  responses=[present,in_use,present,present,in_use,present,present,removed,absent]
  errors=[]
  with patch.object(live_cleanup,'command',side_effect=responses) as command, patch.object(live_cleanup.time,'sleep') as sleep:
   live_cleanup.remove_owned('network','live-net','inv-1',errors,'test network')
  self.assertEqual(errors,[])
  self.assertEqual(command.call_count,9)
  self.assertEqual(sum(call.args[0]==['podman','network','rm','-f','live-net'] for call in command.call_args_list),3)
  self.assertEqual(sleep.call_count,2)
  sleep.assert_called_with(live_cleanup.NETWORK_RETRY_DELAY_SECONDS)
 def test_network_cleanup_does_not_retry_permanent_removal_failure(self):
  labels={
   'org.woow-tailscale.project':'woow-tailscale-gateway',
   'org.woow-tailscale.role':'live-test',
   'org.woow-tailscale.managed-by':'woow-gateway-lifecycle',
   'org.woow-tailscale.invocation':'inv-1',
  }
  present=SimpleNamespace(returncode=0,stdout=json.dumps([{'Labels':labels}]),stderr='')
  denied=SimpleNamespace(returncode=1,stdout='',stderr='Error: permission denied')
  errors=[]
  with patch.object(live_cleanup,'command',side_effect=[present,denied,present]) as command, patch.object(live_cleanup.time,'sleep') as sleep:
   live_cleanup.remove_owned('network','live-net','inv-1',errors,'test network')
  self.assertEqual(errors,['test network removal failed'])
  self.assertEqual(command.call_count,3)
  sleep.assert_not_called()
 def test_network_cleanup_bounds_persistent_in_use_retries(self):
  labels={
   'org.woow-tailscale.project':'woow-tailscale-gateway',
   'org.woow-tailscale.role':'live-test',
   'org.woow-tailscale.managed-by':'woow-gateway-lifecycle',
   'org.woow-tailscale.invocation':'inv-1',
  }
  present=SimpleNamespace(returncode=0,stdout=json.dumps([{'Labels':labels}]),stderr='')
  in_use=SimpleNamespace(returncode=2,stdout='',stderr='Error: network live-net is in use')
  def fake_command(args):
   return in_use if args[:4]==['podman','network','rm','-f'] else present
  errors=[]
  with patch.object(live_cleanup,'command',side_effect=fake_command) as command, patch.object(live_cleanup.time,'sleep') as sleep:
   live_cleanup.remove_owned('network','live-net','inv-1',errors,'test network')
  self.assertEqual(errors,['test network remained in use after bounded removal retries'])
  self.assertEqual(sum(call.args[0]==['podman','network','rm','-f','live-net'] for call in command.call_args_list),live_cleanup.NETWORK_REMOVE_ATTEMPTS)
  self.assertEqual(sleep.call_count,live_cleanup.NETWORK_REMOVE_ATTEMPTS-1)
 def test_network_cleanup_does_not_retry_inspect_errors(self):
  broken=SimpleNamespace(returncode=125,stdout='',stderr='Error: database is locked')
  errors=[]
  with patch.object(live_cleanup,'command',return_value=broken) as command, patch.object(live_cleanup.time,'sleep') as sleep:
   live_cleanup.remove_owned('network','live-net','inv-1',errors,'test network')
  self.assertEqual(errors,['test network inspection failed; absence cannot be verified'])
  command.assert_called_once_with(['podman','network','inspect','live-net'])
  sleep.assert_not_called()
 def test_child_containers_are_removed_before_owned_network_force(self):
  labels={
   'org.woow-tailscale.project':'woow-tailscale-gateway',
   'org.woow-tailscale.role':'live-test',
   'org.woow-tailscale.managed-by':'woow-gateway-lifecycle',
   'org.woow-tailscale.invocation':'inv-1',
  }
  present={'probe':True,'client':True,'network':True}; calls=[]
  def fake_command(args):
   calls.append(args)
   if args[:3]==['podman','container','inspect']:
    name=args[3]
    if present[name]: return SimpleNamespace(returncode=0,stdout=json.dumps([{'Labels':labels}]),stderr='')
    return SimpleNamespace(returncode=1,stdout='',stderr=f'Error: no such container {name}')
   if args[:3]==['podman','rm','-f']:
    present[args[3]]=False; return SimpleNamespace(returncode=0,stdout='',stderr='')
   if args[:3]==['podman','network','inspect']:
    if present['network']: return SimpleNamespace(returncode=0,stdout=json.dumps([{'Labels':labels}]),stderr='')
    return SimpleNamespace(returncode=1,stdout='',stderr='Error: unable to find network live-net')
   if args[:4]==['podman','network','rm','-f']:
    self.assertFalse(present['probe']); self.assertFalse(present['client'])
    present['network']=False; return SimpleNamespace(returncode=0,stdout='',stderr='')
   if args[-4:]==['nodes','list','--output','json']:
    return SimpleNamespace(returncode=0,stdout='[]',stderr='')
   return SimpleNamespace(returncode=2,stdout='',stderr='unexpected argv')
  argv=['live_cleanup.py','--headscale','headscale','--invocation','inv-1','--probe','probe','--container','client','--container-created','--network','live-net','--network-created']
  with patch('sys.argv',argv), patch.object(live_cleanup,'command',side_effect=fake_command):
   live_cleanup.main()
  self.assertFalse(any(present.values()))
  self.assertLess(calls.index(['podman','rm','-f','probe']),calls.index(['podman','network','rm','-f','live-net']))
  self.assertLess(calls.index(['podman','rm','-f','client']),calls.index(['podman','network','rm','-f','live-net']))
 def test_network_cleanup_never_forces_a_foreign_network(self):
  labels={
   'org.woow-tailscale.project':'woow-tailscale-gateway',
   'org.woow-tailscale.role':'live-test',
   'org.woow-tailscale.managed-by':'woow-gateway-lifecycle',
   'org.woow-tailscale.invocation':'another-invocation',
  }
  foreign=SimpleNamespace(returncode=0,stdout=json.dumps([{'Labels':labels}]),stderr='')
  errors=[]
  with patch.object(live_cleanup,'command',return_value=foreign) as command:
   live_cleanup.remove_owned('network','live-net','inv-1',errors,'test network')
  self.assertEqual(command.call_count,1)
  self.assertEqual(command.call_args.args[0],['podman','network','inspect','live-net'])
  self.assertEqual(errors,['test network is foreign; refusing removal'])
 def test_headscale_delete_uses_global_force_and_verifies_absence(self):
  present=SimpleNamespace(returncode=0,stdout='[{"id":9,"given_name":"temp","ip_addresses":["100.64.0.2"]}]',stderr='')
  absent=SimpleNamespace(returncode=0,stdout='[]',stderr='')
  deleted=SimpleNamespace(returncode=0,stdout='',stderr='')
  responses=[present,deleted,absent]
  argv=['live_cleanup.py','--headscale','headscale','--invocation','inv-1','--node-id','9','--node-hostname','temp','--node-ip','100.64.0.2']
  with patch('sys.argv',argv), patch.object(live_cleanup,'command',side_effect=responses) as command:
   live_cleanup.main()
  self.assertEqual(command.call_args_list[1].args[0],['podman','exec','headscale','headscale','--force','nodes','delete','--identifier','9'])
  self.assertEqual(command.call_args_list[2].args[0],['podman','exec','headscale','headscale','nodes','list','--output','json'])
 def test_restart_and_recheck(self):
  self.assertIn('nginx-proxy-manager.service odoo18.service woow-tailscale-gateway.service',S)
  self.assertNotIn('container-nginx-proxy-manager.service',S); self.assertNotIn('container-odoo.service',S)
  self.assertGreater(S.count('http_check 18081'),1); self.assertGreater(S.count('http_check 18069'),1)
 def test_complete_fake_command_sequence_uses_named_probes_and_cleanup(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory)/'checkout'; (root/'scripts').mkdir(parents=True); (root/'runtime').mkdir(mode=0o700)
   shutil.copy2('scripts/live-test.sh',root/'scripts/live-test.sh')
   shutil.copy2('scripts/runtime_file.py',root/'scripts/runtime_file.py')
   log=Path(directory)/'commands'
   stubs={
    'verify.sh':'#!/bin/sh\nprintf "verify\\n" >>"$COMMAND_LOG"\nprintf "{\\"live_test_status\\":\\"not-run\\"}\\n" >runtime/last-verification.json\n',
    'service_ownership.py':'#!/usr/bin/env python3\nimport os\nopen(os.environ["COMMAND_LOG"],"a").write("ownership\\n")\n',
    'live_cleanup.py':'#!/usr/bin/env python3\nimport os,sys\nopen(os.environ["COMMAND_LOG"],"a").write("cleanup "+" ".join(sys.argv[1:])+"\\n")\n',
    'gateway_config.py':'''#!/usr/bin/env python3\nprint('{"HEADSCALE_CONTAINER":"headscale","GATEWAY_HOSTNAME":"gateway","HEADSCALE_URL":"http://127.0.0.1:28080"}')\n''',
    'headscale_json.py':'''#!/usr/bin/env python3
import os,sys
if sys.argv[1]=='default-user-id': print('1')
elif sys.argv[1]=='extract-preauth':
 open(sys.argv[3],'w').write('7\\n');open(sys.argv[4],'w').write('opaque\\n');os.chmod(sys.argv[3],0o600);os.chmod(sys.argv[4],0o600)
elif sys.argv[1]=='find-node': print('9')
'''}
   for name,body in stubs.items(): p=root/'scripts'/name;p.write_text(body);p.chmod(0o755)
   (root/'runtime/gateway-self-id').write_text('self-gateway\n'); (root/'runtime/gateway-self-id').chmod(0o600)
   (root/'.env.gateway').write_text('stub\n'); (root/'.env.gateway').chmod(0o600)
   fake=Path(directory)/'bin'; fake.mkdir()
   systemctl=fake/'systemctl'; systemctl.write_text('#!/bin/sh\nprintf "restart %s\\n" "$*" >>"$COMMAND_LOG"\n'); systemctl.chmod(0o755)
   sleep=fake/'sleep'; sleep.write_text('#!/bin/sh\nexit 0\n'); sleep.chmod(0o755)
   podman=fake/'podman'; podman.write_text(textwrap.dedent('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['COMMAND_LOG'],'a') as f:f.write('podman '+' '.join(sys.argv[1:])+'\\n')
a=sys.argv[1:]
if a[:2]==['image','inspect']: print('sha256:'+'a'*64);raise SystemExit(0)
if a[:2] in (['network','create'],['volume','create']): raise SystemExit(0)
if a and a[0]=='run':
 mounts=[a[i+1] for i,x in enumerate(a[:-1]) if x=='--volume']
 secrets=[x for x in mounts if x.endswith(':/run/secrets/live-preauth.key:ro')]
 if secrets:
  source=secrets[0].removesuffix(':/run/secrets/live-preauth.key:ro')
  expected=os.path.join(os.environ['CHECKOUT'],'runtime')
  mode=os.stat(source).st_mode & 0o777
  if not os.path.isabs(source) or os.path.dirname(source)!=expected or os.path.islink(source) or mode!=0o600:
   print('invalid secret bind source',file=sys.stderr);raise SystemExit(3)
 if '-w' in a: print('200')
 raise SystemExit(0)
if a and a[0]=='exec':
 if 'users' in a and 'list' in a: print('[]')
 elif 'preauthkeys' in a and 'create' in a: print('{"id":7,"key":"opaque"}')
 elif 'preauthkeys' in a and 'list' in a: print('[]')
 elif 'nodes' in a and 'list' in a: print('[{"id":9,"given_name":"test","ip_addresses":["100.64.0.2"]}]')
 elif 'status' in a and '--json' in a:
  if a[1]=='woow-tailscale-gateway': print('{"Self":{"ID":"self-gateway"}}')
  else: print('{"Self":{"TailscaleIPs":["100.64.0.2"]},"Peer":{"x":{"HostName":"gateway","TailscaleIPs":["100.64.0.1"]}}}')
 elif 'ping' in a:
  if any(x.startswith('--type') for x in a):
   print('flag provided but not defined: -type',file=sys.stderr);raise SystemExit(64)
  if '--peerapi' in a:
   if a[-4:]!=['ping','--peerapi','--timeout=5s','100.64.0.1']: raise SystemExit(65)
  else: print('pong via 192.0.2.1:41641')
 raise SystemExit(0)
raise SystemExit(0)
''')); podman.chmod(0o755)
   env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'COMMAND_LOG':str(log),'XDG_RUNTIME_DIR':directory,'CHECKOUT':str(root)}
   result=subprocess.run(['bash','scripts/live-test.sh'],cwd=root,text=True,capture_output=True,env=env)
   self.assertEqual(result.returncode,0,result.stderr)
   lines=log.read_text().splitlines(); joined='\n'.join(lines)
   self.assertEqual(sum('podman run --name woow-gateway-test-' in x and '-http-' in x for x in lines),4)
   first_probe=next(i for i,x in enumerate(lines) if 'podman run --name' in x and '-http-' in x)
   restart=next(i for i,x in enumerate(lines) if x.startswith('restart --user restart'))
   probes=[i for i,x in enumerate(lines) if 'podman run --name' in x and '-http-' in x]
   self.assertLess(probes[1],restart); self.assertLess(restart,probes[2])
   self.assertIn('ownership',joined); self.assertTrue(lines[-1].startswith('cleanup '))
   client_run=next(x for x in lines if x.startswith('podman run -d --name'))
   self.assertIn(f'--volume {root}/runtime/.live-enrollment.',client_run)
   self.assertIn(':/run/secrets/live-preauth.key:ro',client_run)
   peerapi=next(x for x in lines if ' ping --peerapi ' in x)
   self.assertTrue(peerapi.endswith(' tailscale --socket=/tmp/tailscaled.sock ping --peerapi --timeout=5s 100.64.0.1'),peerapi)
if __name__=='__main__': unittest.main()
