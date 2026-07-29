# JurisVoice infrastructure agent instructions

## Start here

- Read `README.md`, `config.psd1`, and `.codex/context.md` before acting.
- Use `run.ps1` as the canonical idempotent entry point.
- Treat `state/current.json`, AWS identity, public IP, DNS, and service health as volatile; verify them live.
- Do not modify the JurisVoice application, Vercel records, email records, or client `/dashboard`.

## Runtime and package manager

- Host runtime: Windows PowerShell 5.1+, AWS CLI v2, and Windows OpenSSH.
- Server runtime: Ubuntu 24.04, Bash, Docker Engine, and Docker Swarm.
- There is no project package manager or dependency-install step.

## Common commands

- Infrastructure: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run.ps1`
- Full safe reconcile: add `-EnsureCloudflareDns -ProvisionPlatform -VerifyPlatform`.
- Read-only checks: `.\status.ps1` and `.\scripts\verify-platform.ps1`.
- SSH: `ssh server` or `.\connect.ps1`.
- File-scoped PowerShell syntax check: use the parser command in `README.md`.
- Bash syntax check: copy to the server and run `bash -n`.

## Safety rules

- Never store AWS keys, session tokens, Cloudflare tokens, passwords, or private SSH keys here.
- Keep the private key at `C:\Users\adam\.ssh\aws-ubuntu-server-1`.
- Keep browser authentication and MFA enabled; never replace them with long-lived credentials.
- Never expose port 3000; public ingress is only TCP 80/443, with SSH limited to the current `/32`.
- Never terminate an instance, delete a volume/key pair, or broaden SSH without explicit user approval.
- Identify the server by both `Name=ubuntu-server-1` and `Project=codex-ubuntu`.
- If multiple active managed instances, zones, or matching DNS records exist, stop and report ambiguity.
- Keep Cloudflare records DNS-only unless the user explicitly approves a reviewed proxy change.

## Conventions

- Scripts must be idempotent, fail closed on ambiguity, and avoid printing secrets.
- Put durable guidance under `foundational/`; keep `AGENTS.md` concise.
- Store server-generated secrets only as root-owned mode-600 files documented in the runbook.
- Record current non-secret state in `state/`; write operational output to `logs/`.

## Commit attribution

- Do not commit or push unless the user explicitly requests it.
- If requested, preserve existing authorship and do not add assistant attribution.
