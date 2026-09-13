import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path
B=Path('scripts/backup.sh').read_text(); R=Path('scripts/restore.sh').read_text()
class BackupRestoreContract(unittest.TestCase):
 def test_cold_atomic_backup(self):
  for x in ('volume export --output','systemctl --user stop','SHA256SUMS','manifest.json','mv -T --no-clobber "$temp" "$out"','scripts/verify.sh'): self.assertIn(x,B)
  self.assertIn('backup must be outside the repository',B); self.assertIn('identity changed after backup',B)
 def test_safe_transactional_restore(self):
  for x in ('--confirm-restore','unexpected archive members','unsafe archive member','sha256sum --strict -c','volume import','rollback_retained','exact Self.ID'): self.assertIn(x,R)
  self.assertIn('resource_ownership.py check-volume',R); self.assertIn('protected rollback archive retained',R); self.assertIn('scripts/verify.sh',R)
 def test_shared_lock(self):
  self.assertIn('woow-tailscale-gateway.lock',B); self.assertIn('woow-tailscale-gateway.lock',R)
 def test_restore_rejects_adversarial_archives_before_mutation(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory)/'checkout'; (root/'scripts').mkdir(parents=True); (root/'runtime').mkdir(mode=0o700)
   shutil.copy2('scripts/restore.sh',root/'scripts/restore.sh')
   ownership=root/'scripts/resource_ownership.py'; ownership.write_text('''#!/usr/bin/env python3
import os
p=os.environ.get("REPLACE_ARCHIVE")
if p and not os.path.islink(p):
 os.unlink(p);os.symlink(os.environ["REPLACEMENT"],p)
'''); ownership.chmod(0o755)
   (root/'runtime/gateway-self-id').write_text('self\n'); (root/'runtime/gateway-self-id').chmod(0o600)
   fake=Path(directory)/'bin'; fake.mkdir(); log=Path(directory)/'commands'
   for name in ('podman','systemctl'):
    p=fake/name; p.write_text('#!/bin/sh\nprintf "%s %s\\n" "$(basename "$0")" "$*" >>"$COMMAND_LOG"\nexit 99\n'); p.chmod(0o755)
   labels={'org.woow-tailscale.project':'woow-tailscale-gateway','org.woow-tailscale.role':'state','org.woow-tailscale.managed-by':'woow-gateway-lifecycle','org.woow-tailscale.checkout':str(root)}
   manifest=json.dumps({'schema':2,'checkout':str(root),'self_id':'self','volume':'woow-tailscale-gateway-state','volume_labels':labels}).encode()
   state=b'state'
   def checksums(duplicate=False):
    lines=[hashlib.sha256(manifest).hexdigest().encode()+b'  manifest.json',hashlib.sha256(state).hexdigest().encode()+b'  state.tar']
    if duplicate: lines.append(lines[0])
    return b'\n'.join(lines)+b'\n'
   def archive(name,members):
    path=Path(directory)/name
    with tarfile.open(path,'w') as tf:
     for member_name,data,kind in members:
      info=tarfile.TarInfo(member_name); info.mode=0o600
      if kind=='symlink': info.type=tarfile.SYMTYPE;info.linkname='state.tar';info.size=0;tf.addfile(info)
      else: info.size=len(data);tf.addfile(info,io.BytesIO(data))
    return path
   valid=[('manifest.json',manifest,'file'),('SHA256SUMS',checksums(),'file'),('state.tar',state,'file')]
   cases={
    'traversal.tar':[('../manifest.json',manifest,'file'),('SHA256SUMS',checksums(),'file'),('state.tar',state,'file')],
    'symlink.tar':[('manifest.json',manifest,'file'),('SHA256SUMS',checksums(),'file'),('state.tar',b'','symlink')],
    'unexpected.tar':valid+[('extra',b'x','file')],
    'duplicate-member.tar':valid+[('state.tar',state,'file')],
    'duplicate-checksum.tar':[('manifest.json',manifest,'file'),('SHA256SUMS',checksums(True),'file'),('state.tar',state,'file')],
    'malformed-manifest.tar':[('manifest.json',b'{','file'),('SHA256SUMS',hashlib.sha256(b'{').hexdigest().encode()+b'  manifest.json\n'+hashlib.sha256(state).hexdigest().encode()+b'  state.tar\n','file'),('state.tar',state,'file')],
   }
   env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'COMMAND_LOG':str(log),'XDG_RUNTIME_DIR':directory}
   for name,members in cases.items():
    with self.subTest(name=name):
     log.unlink(missing_ok=True); path=archive(name,members)
     result=subprocess.run(['bash','scripts/restore.sh',str(path),'--confirm-restore'],cwd=root,text=True,capture_output=True,env=env)
     self.assertNotEqual(result.returncode,0); self.assertFalse(log.exists(),result.stderr)
   replacement=archive('replacement.tar',valid); selected=archive('replace-me.tar',valid)
   replaced=subprocess.run(['bash','scripts/restore.sh',str(selected),'--confirm-restore'],cwd=root,text=True,capture_output=True,env={**env,'REPLACE_ARCHIVE':str(selected),'REPLACEMENT':str(replacement)})
   self.assertNotEqual(replaced.returncode,0); self.assertFalse(log.exists())
 def test_export_failure_restarts_and_verifies_exact_identity(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory)/'checkout'; (root/'scripts').mkdir(parents=True); (root/'runtime').mkdir(mode=0o700)
   shutil.copy2('scripts/backup.sh',root/'scripts/backup.sh')
   (root/'scripts/resource_ownership.py').write_text('#!/usr/bin/env python3\nraise SystemExit(0)\n')
   (root/'scripts/verify.sh').write_text('#!/bin/sh\nprintf "verify\\n" >>"$COMMAND_LOG"\n')
   for path in (root/'scripts').iterdir(): path.chmod(0o755)
   (root/'runtime/gateway-self-id').write_text('self-1\n'); (root/'runtime/gateway-self-id').chmod(0o600)
   fake=Path(directory)/'bin'; fake.mkdir(); log=Path(directory)/'commands'
   systemctl=fake/'systemctl'; systemctl.write_text('#!/bin/sh\nprintf "systemctl %s\\n" "$*" >>"$COMMAND_LOG"\nexit 0\n'); systemctl.chmod(0o755)
   podman=fake/'podman'; podman.write_text(textwrap.dedent('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['COMMAND_LOG'],'a') as f:f.write('podman '+' '.join(sys.argv[1:])+'\\n')
a=sys.argv[1:]
if a[:2]==['volume','export']: raise SystemExit(8)
if a and a[0]=='exec': print(json.dumps({'Self':{'ID':'self-1'}}));raise SystemExit(0)
raise SystemExit(2)
''')); podman.chmod(0o755)
   out=Path(directory)/'backup.tar'
   result=subprocess.run(['bash','scripts/backup.sh',str(out)],cwd=root,text=True,capture_output=True,env={**os.environ,'PATH':f"{fake}:{os.environ['PATH']}",'COMMAND_LOG':str(log),'XDG_RUNTIME_DIR':directory})
   self.assertNotEqual(result.returncode,0)
   commands=log.read_text(); self.assertLess(commands.index('systemctl --user stop'),commands.index('systemctl --user start'))
   self.assertIn('verify',commands); self.assertIn('exact prior Self.ID verified',result.stderr)
   self.assertFalse(out.exists()); self.assertEqual(list(Path(directory).glob('.woow-gateway-backup.*')),[])
if __name__=='__main__': unittest.main()
