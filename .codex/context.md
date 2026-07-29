# Codex context index

This directory is the durable context entry point for future Codex sessions.
`AGENTS.md` is canonical and should remain short.

Read in this order:

1. `AGENTS.md` for mandatory boundaries and commands.
2. `README.md` for the operator workflow and current completed state.
3. `config.psd1` for the managed AWS target.
4. `foundational/specs/platform.md` for desired architecture and acceptance checks.
5. `foundational/rules/operations.md` for safe sequencing.
6. `foundational/rules/recovery.md` for previously fixed failures.
7. `foundational/api/external-services.md` for authentication and API behavior.

Codex does not need a duplicate `CODEX.md`. It automatically consumes
`AGENTS.md`; this index keeps detailed context outside that instruction file.
