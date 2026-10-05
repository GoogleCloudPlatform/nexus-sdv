# AGENTS.md

The guidance for coding agents working in this repository lives in
[CLAUDE.md](CLAUDE.md): what each component is, how to build and test it, how
the data flows between them, and how deployment works.

Task-level instructions for installing and operating a Nexus platform ship as a
plugin, `nexus-sdv`, in [`.agents/plugins/nexus-sdv/skills/`](.agents/plugins/nexus-sdv/skills/):

- `nexus-install` — check a Google Cloud project, write the configuration, run
  the bootstrap, read the result, tear it down again
- `nexus-operate` — health, certificate expiry, telemetry through a running
  platform, which vehicles it knows

If your agent does not pick them up on its own, point it at the `SKILL.md` files
directly; they are plain Markdown and stand on their own.
