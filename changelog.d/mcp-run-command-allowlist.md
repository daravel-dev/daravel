### Changed

- `dartisan mcp:serve --allow-write`: `run_command` reads the command with dartisan's own parser before it decides, so global flags in front (`--no-color`, `--ansi`), `--` and aliases name the command that would really run, and a `command` starting with `-` is refused. It offers a fixed list (`mcpOfferedCommands`, every `make:*`, and `mcpOfferedOutsideProduction` outside production) and refuses any other command; `migrate --seed` is refused in production whatever the flags. `mcp:serve --allow-command=<name>` (repeatable, with `--allow-write`) opens a further command, such as a project's own; it cannot open `mcpNeverOffered`, nor `mcpProductionOnlyInTerminal` in production. The tool's description lists what is offered. Guide: [dartisan](docs/guide/dartisan.md).
- `queue:flush --hours=<value>`: a value that is not a whole number of hours above 0 is a usage error (exit 64) and deletes nothing.
- `queue:clear` needs `--force` when `APP_ENV=production`, as artisan's (`ConfirmableTrait`); `queue:flush` has no such guard, as artisan's.

### Upgrade notes

- `run_command` refuses commands outside its list that it used to run (the project's own commands, `db:backup`, `pub:add`, `build`, ...): open each with `mcp:serve --allow-write --allow-command=<name>` in `.mcp.json`. `McpServer(runner:)` is now needed for `run_command`; without it every command is refused (`mcp:serve` passes its runner). `mcpRefusedCommands` and `mcpProductionRefused` are deprecated (`mcpNeverOffered`, `mcpProductionOnlyInTerminal`). New public names `mcpOfferedCommands`, `mcpOfferedOutsideProduction`, `mcpNeverOffered` and `mcpProductionOnlyInTerminal` in `package:dartisan_cli`.
- A script running `queue:clear` in production needs `--force`; one passing `queue:flush --hours` a value such as `24h` or `0` now fails instead of deleting every failed job.
