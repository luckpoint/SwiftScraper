# swiftscraper skill evals

Fifteen cases: five happy paths, five negatives the skill must not fire on, and
five traces built from real conflicts in the CLI. Checks are regex over the
agent's response — no judge model, so a full pass costs only agent calls.

```bash
python3 run_eval.py                      # with skill, 3 trials per case
python3 run_eval.py --mode both          # ablation: measures skill lift
python3 run_eval.py --group negative     # false-firing only
python3 run_eval.py --case happy-bidi-puppeteer --trials 5
```

Point the harness at another harness with `SWIFTSCRAPER_EVAL_AGENT`:

```bash
SWIFTSCRAPER_EVAL_AGENT="gemini -m gemini-3-flash-preview -o json -y" python3 run_eval.py
```

## What the cases protect

`happy-bidi-puppeteer` is a regression test. The BiDi server began requiring a
bearer token in `ec07135`, and SKILL.md kept handing out an unauthenticated
`puppeteer.connect` example until this suite was added. The case fails if the
example drops `bidiHeaders`.

The `trace-*` cases cover option combinations the CLI rejects — `--cookie-jar`
with batch mode, `--markdown` with `--pretty-print`, `--pdf` with
`--download-pdfs`, and a non-loopback `--bidi-host`. They grade the outcome, not
whether the agent read SKILL.md first.

## Known gap

`trace-browser-cookies` fails today on purpose: SKILL.md documents `--cookie-file`
but not `--browser-cookies` / `--browser-profile`. It passes once the Cookies
section covers browser-profile import.

## Adding cases

Append to `cases.json` with `expect` (every pattern must match) and `reject` (no
pattern may match). Every bug found in real use should land here as a case before
the fix, so the suite grows out of production instead of imagination.
