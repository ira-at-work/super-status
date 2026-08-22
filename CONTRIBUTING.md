# Contributing to super-status

Thanks for wanting to help. super-status is a single Bash script
(`statusline.sh`) plus a `bats` test suite — small enough that a good change is
easy to review and easy to land.

## Ground rules

- **One behavior per pull request.** A focused diff reviews faster and reverts
  cleanly.
- **Every change ships with a test.** New display logic, a new config key, a new
  backend mode — all of it goes into `tests/statusline.bats`. A change with no
  test that could have had one will be asked to add it.
- **Keep it POSIX-friendly Bash.** The script runs on both GNU (Linux) and BSD
  (macOS) userlands, so `date`/`stat` and friends carry dual code paths. If you
  touch one, check the other.
- **Comments explain _why_, not _what_.** The code says what it does; a comment
  earns its place only when the reason isn't obvious from reading it.

## Local setup

You need three tools:

```
jq          # JSON parsing
shellcheck  # lint
bats        # test runner
```

Install them with your package manager:

```
# macOS
brew install jq shellcheck bats-core

# Debian / Ubuntu
sudo apt-get install -y jq shellcheck bats
```

## Before you open a pull request

Run the same checks CI runs:

```
shellcheck statusline.sh doctor.sh install.sh
bats tests/
```

Both must be clean. CI runs them on `ubuntu-latest` and `macos-latest`, so a
change that passes only on your platform will fail there.

## Adding a config key

Config lives in `~/.claude/super-status/config.json` and is parsed in one `jq`
pass near the top of `statusline.sh`. To add a key:

1. Add its default to the `cfg_*` defaults block.
2. Emit it in the config `jq` filter and handle it in the `case` that reads the
   rows back.
3. Use it where the segment renders.
4. Document it in `README.md`.
5. Add a `bats` test proving the default and the override.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):
`feat(...)`, `fix(...)`, `refactor(...)`, `test(...)`, `docs(...)`, `chore(...)`.
Write the subject in the imperative mood ("add", not "added").

## Reporting bugs and requesting features

Open an issue using the templates — they ask for the few things needed to
reproduce a statusline bug (your config, the rough stdin shape, your platform).
For anything security-sensitive, follow [`SECURITY.md`](SECURITY.md) instead of
filing a public issue.
