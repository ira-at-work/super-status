# super-status — Project Conventions

## Session handoff

When work in `docs/plan*.md` or `docs/upgrade-plan.md` will span more than one
session, end the entry with a `**Next action:**` line stating one concrete,
resumable step — not a summary of what was done. A future session should be
able to act on that line without re-reading the whole revision history.

Example: `**Next action:** implement I7 (move caches to XDG_CACHE_HOME) — see docs/upgrade-plan.md.`

Skip this on entries that close out the work (e.g. a "Revision N — fix"
entry that fully resolves what it describes needs no next-action line).

## Version manager

Every commit is auto-versioned by `.git/hooks/post-commit` →
`scripts/version-bump.sh`: it derives a semver bump from the commit type
(Conventional Commits — `feat` → minor, `!`/`BREAKING CHANGE` → major, else
patch), prepends a plain-English row to the per-year ledger `versions/<year>.md`,
tags the commit `vX.Y.Z`, and pushes the branch + tag with `--force-with-lease`.
Seeded at `v2.5.0` (the CHANGELOG release at setup time).

Write the plain-English change **before committing** so the ledger's "Change"
cell reads well: put one bullet per line in `.git/version-note.md` (consumed and
deleted by the hook). Without a note, the cell falls back to a de-jargoned commit
subject.

One-shot save (stage all + commit + auto version + push):

```
scripts/save.sh <plain description of the change>
```

Never edit `versions/<year>.md` by hand — it is hook-maintained.
