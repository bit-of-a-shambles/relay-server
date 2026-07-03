# Agent guide for Relay Server

This file tells any coding agent (including small/weaker models) how to work in
this repository. Follow it literally. When this file and your own judgement
disagree, follow this file.

## What this repo is

Relay Server is the open-core router + daemon for a mobile remote / cost
router for coding agents. See [docs/PLAN.md](docs/PLAN.md) for the full spec
and [docs/STATUS.md](docs/STATUS.md) for the current state. The iOS client is
closed-source and lives in a separate, private repository; nothing in this
repo depends on it.

Layout:

- `router/` — TypeScript cost router. Implemented, tested, 100% coverage enforced.
- `daemon/` — Ruby + Sorbet Mac-side service. Built milestone-by-milestone from
  [docs/AGENT_PLAYBOOK.md](docs/AGENT_PLAYBOOK.md).
- `menubar/` — macOS menu-bar wrapper (thin daemon-lifecycle UI).

## The Loop

All implementation work happens as repetitions of this loop. One loop iteration
= one milestone = one commit. Never batch multiple milestones into one commit.

1. **Pick.** Open [docs/AGENT_PLAYBOOK.md](docs/AGENT_PLAYBOOK.md). Find the
   first milestone whose checkbox is unchecked (`- [ ]`). That is your entire
   scope for this iteration. Do not look ahead and do not do extra work.
2. **Read.** Read the milestone in full, and read every file it names, before
   writing anything.
3. **Implement.** Make the smallest change that satisfies the milestone's
   "Done when" list.
4. **Test.** Write or extend tests in the same iteration until the coverage
   gates pass (see Validation below). Tests are part of the milestone, not a
   follow-up.
5. **Validate.** Run every validation command for the components you touched.
   All of them must pass. If anything is red, fix it before doing anything
   else. You may not weaken a gate to get to green (see Guardrails).
6. **Document.** Tick the milestone checkbox in `docs/AGENT_PLAYBOOK.md` and
   update `docs/STATUS.md` (move the item into "Completed", refresh
   "Next recommended work", refresh the "Last updated" date).
7. **Commit and push.** One commit, message format:
   `daemon: M<number> <short summary>` (or `router: ...` / `menubar: ...` if
   the milestone is router- or menubar-side). Push with
   `git push -u origin <current branch>`.
8. **Repeat** from step 1, or stop (see Stop conditions).

## Validation commands

Run these from the component directory. They must all exit 0.

Router (`router/`):

```bash
npm ci          # first time only
npm run build
npm test
npm run coverage   # enforces 100% statements/branches/functions/lines
```

Daemon (`daemon/`):

```bash
bundle install     # first time only
bundle exec srb tc # Sorbet typecheck
bundle exec rspec  # tests; SimpleCov enforces 100% line coverage
```

macOS menubar (`menubar/`):

```bash
cd menubar
xcodegen generate
xcodebuild test -project RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS'
xcodebuild build -project RelayMenuBar.xcodeproj -scheme RelayMenuBar -destination 'platform=macOS'
```

## Guardrails

- Never commit to `main`. Work on the branch you were given.
- Never lower or remove a coverage threshold, skip a test, mark a test
  pending, or delete a failing test to get to green.
- Never commit secrets. `OPENROUTER_API_KEY` and tokens live in `.env` /
  environment variables only. `.env` is gitignored; keep it that way.
- Do not refactor code outside your milestone's scope. If you see something
  broken outside scope, note it in `docs/STATUS.md` under "Blocked" or a
  "Known issues" section instead of fixing it now.
- Network calls in tests are forbidden. Test against fakes/fixtures
  (the router test suite shows the pattern).

## Stop conditions

Stop looping and report (in your reply AND in `docs/STATUS.md` under
"Blocked") when any of these happens:

- A milestone needs information only the user has (credentials, product
  decisions, hardware).
- You have attempted the same milestone 3 times and validation still fails.
  Commit nothing for that attempt; describe exactly what fails and paste the
  failing output into the Blocked note.
- All milestones in the playbook are checked. Say so and stop; do not invent
  new work.
