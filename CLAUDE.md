# Environment (exe.dev box)

GitHub access goes through the exe.dev integration: the remote is
`github.int.exe.xyz` and `GH_HOST` is set to it.

- Do not run `gh auth login`.
- Do not change the remote to `github.com`.
- Pass `-R antithesishq/antithesis-triage-action` to `gh` commands if it can't detect the repo.
