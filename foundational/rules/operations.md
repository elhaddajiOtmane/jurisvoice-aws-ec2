# Operations rules

## Safe order of operations

1. Read the project context and inspect `state/current.json`.
2. Run `run.ps1`; complete AWS browser sign-in/MFA if requested.
3. Confirm exactly one managed instance and verify its current public IP.
4. Reconcile only the two isolated Cloudflare A records.
5. Run the idempotent CapRover/n8n provisioner.
6. Run read-only platform verification.
7. Report verified state and any remaining manual action.

## Authentication

- AWS: use the `codex-admin` browser-login profile.
- Cloudflare: place a short-lived scoped token in the current process as
  `CLOUDFLARE_API_TOKEN`; never pass it as a command argument or write it.
- CapRover and n8n passwords: retrieve from the server with an interactive SSH
  session only when needed. Do not copy them into logs, source, state, or memory.
- 1Password: the n8n owner login is stored as `JurisVoice n8n` in the Personal
  vault. Use Windows Hello/user approval; never export the vault item.

## Change boundaries

- Existing JurisVoice/Vercel/email DNS is out of scope.
- The JurisVoice repository and client `/dashboard` are out of scope.
- `run.ps1` may create or resize the managed paid instance, but never deletes it.
- DNS automation may create/update only the two exact records in the spec.
- Provisioning may update only CapRover, n8n, PostgreSQL, and their named volumes.

## Secret locations on the server

The following are root-owned mode-600 files and must not be printed in routine
verification:

- `/root/caprover-admin-password`
- `/root/n8n-postgres-password`
- `/root/n8n-encryption-key`
- `/root/n8n-owner-password`

The private SSH key remains at
`C:\Users\adam\.ssh\aws-ubuntu-server-1`.
