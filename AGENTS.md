# Instructions for agents

## Ruby comments

Follow the skill in [llm/skills/ruby-commenting](llm/skills/ruby-commenting/SKILL.md) (read its
[exemplars](llm/skills/ruby-commenting/exemplars.md) too) for implementation comments in Ruby: no
comment unless the code can't say it, and terse when there is one. It doesn't cover YARD, which
documents every method here, private ones included (`bundle exec rake yard:lint` checks it).
Claude Code picks the skill up through the symlink in `.claude/skills/`.

Mark what users are not meant to call with `@api private`: classes and modules that only the
library uses (YARD carries the tag down to everything inside them, so a public struct nested in
one gets `@api public`), and public methods kept public only for other parts of the library.
Private methods need no tag.

## Loading

`lib/herringbone.rb` loads nothing but StringIO and the version: every other file is autoloaded
(`autoload` in `lib/herringbone.rb`, or in the file of the class it belongs to, like
`Reader::Filter`). A new file gets an `autoload` entry, not a `require_relative`; reopening a
class from another file (as `reader/bloom_filters.rb` does) is required by that class's own file.
`test/autoload_test.rb` checks that `Herringbone.eager_load!` reaches every file under `lib/`.

## CHANGELOG

`CHANGELOG.md` lists user-visible changes per version, newest first. Add the entry in the same
commit or PR as the change itself.

- Changes that are not released yet go under `## Unreleased` at the top. Do not bump the version
  or invent a version heading for them. On release, `## Unreleased` is renamed to the new version
  (`## 0.4.0`, matching `lib/herringbone/version.rb` and the `v0.4.0` tag).
- One bullet per change, one sentence (two at most), ending with a period. Terse: say what a user
  can now do or what behaves differently, not how it was implemented.
- Lead with the public name in backticks when there is one: `` `Herringbone::SimpleWriter`: ... ``,
  `` `read(as: :numo)` and `each_batch(as: :numo)` return ... ``, `` `herringbone inspect ...` ``.
- Name the optional gem a feature needs, in backticks: "(optional `numo-narray-alt`)".
- Give a number when a speedup was measured, once: "27x faster compression".
- Mark incompatible changes with `**Breaking:**` and say what replaces the old API:
  "**Breaking:** `herringbone inspect` takes `--format=text|json|html` instead of `--json`/`--html`."
  Put them after the other entries of their version.
- Leave out what users never see: CI, linting, tests, refactors, benchmarks, `llm/` write-ups, and
  README edits that only rephrase.
- Wrap lines at 100 characters, indenting continuation lines by two spaces.

For example:

```markdown
## Unreleased

- `Herringbone.write(io, rows) { json :payload }` declares fields that replace inferred ones.
- `Herringbone.write` without `schema:` reads the rows once, holding back only the first 1000 for
  inference, so cursors and one-shot Enumerators no longer lose rows.
- **Breaking:** `herringbone inspect` takes `--format=text|json|html` instead of `--json`/`--html`.
```
