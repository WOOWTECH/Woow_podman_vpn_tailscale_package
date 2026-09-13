import unittest
from pathlib import Path
S=Path('systemd/woow-tailscale-gateway.service.in').read_text(); H=Path('scripts/container-health.sh').read_text()
class RuntimeContracts(unittest.TestCase):
 def test_rootless_host_runtime(self):
  for x in ('--network=host','--env-file=%h/.config/woow-tailscale-gateway/gateway.env','woow-tailscale-gateway-state:/var/lib/tailscale','--sdnotify=conmon','Restart=always'): self.assertIn(x,S)
  for x in ('--publish','--device','--cap-add','TS_AUTHKEY','caddy'): self.assertNotIn(x,S.lower() if x=='caddy' else S)
 def test_labels(self):
  for x in ('project','role','managed-by','checkout'): self.assertIn('org.woow-tailscale.'+x,S)
 def test_health_exact(self):
  self.assertIn('.BackendState == "Running"',H); self.assertIn('["18069","18081"]',H)
  self.assertIn('/dev/tcp/127.0.0.1/$port',H)
  self.assertIn('--health-cmd=/usr/local/bin/woow-gateway-health',S)
  self.assertIn('COPY scripts/container-health.sh /usr/local/bin/woow-gateway-health',Path('Containerfile').read_text())
if __name__=='__main__': unittest.main()
