# Recovery notes

## Docker package unavailable

- Symptom: `Package 'docker-ce' has no installation candidate`.
- Cause: malformed deb822 `docker.sources`.
- Fix: quarantine the malformed file and use:
  `deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable`
  in `/etc/apt/sources.list.d/docker.list`.

## CapRover permanent service at 0/1

- Symptom: `captain-captain` cannot bind ports 80/443.
- Cause: temporary bootstrap container still owns the ports.
- Fix: remove only the temporary bootstrap container, then recheck Swarm.

## CapRover login rejected

- The CapRover API requires header `x-namespace: captain`.
- After HTTPS is forced, use the public HTTPS API, not local HTTP.
- If the password hash must be reset, first scale `captain-captain` to zero,
  back up `/captain/data/config-captain.json`, remove only `hashedPassword`,
  add a temporary `DEFAULT_PASSWORD`, then scale the service back to one.
- Rotate the password immediately and remove `DEFAULT_PASSWORD`.
- Never repeat a reset blindly; inspect current service/config state first.

## Quoting and execution policy

- Run scripts with:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`.
- Invoke executable paths containing spaces with PowerShell call operator `&`.

## Cloudflare/Let’s Encrypt

- CapRover initialization and certificate issuance require DNS-only records.
- If issuance fails, verify exact A records, public 80/443 ingress, and that no
  Cloudflare proxy is active before retrying.
- A Cloudflare token was exposed in the original chat; revoke/rotate it before
  reuse. Never preserve it in a file or memory.

## Verification false positives

- A single local Windows connection probe can be misleading.
- Cross-check public HTTPS, DNS resolution, server-side `curl`, Swarm replicas,
  and an external port-3000 probe before declaring success.
