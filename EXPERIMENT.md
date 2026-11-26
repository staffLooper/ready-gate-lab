# Chunk 0: what GitHub really does under the ready gate

- **Status:** plan. Nothing here has run. No App, key or environment exists yet.
- **Serves:** [staffLooper/stafflooper#419](https://github.com/staffLooper/stafflooper/pull/419), the sponsor's 2026-11-25 decision "419: run chunk 0's experiment first", then one design round on measured behaviour. ADR-0082 ([file](https://github.com/staffLooper/stafflooper/blob/main/docs/adr/0082-the-ready-gate-is-a-required-github-check-fed-only-by-verdicts-code-records.md)), decision 2.2, decision 3.5, R10 and build chunk 0.
- **Owner:** the Architect (the plan). The session runs it after the sponsor's go. The sponsor creates the App, key and environment.

**This plan tests the GitHub behaviours ADR-0082 depends on but nobody has checked. Each gets a committed script, its captured output and a PASS, FAIL or MEASURED reading.**
- PASS or FAIL: the ADR states the behaviour, and the run confirms it or refutes it.
- MEASURED: the ADR needs a number or a shape, and the run records it.
- The design round reads these results. This plan decides nothing about the design.

## Where each claim comes from
Every statement here about how GitHub behaves is **unchecked until its experiment runs**. The "Source" column says who made the claim:
- **relayed:** ADR-0082 or a #419 review says it, citing GitHub's docs, and nobody has checked it;
- **mine:** the Architect's recollection of GitHub's docs, also unchecked;
- **seen:** read in this session, 2026-11-25, with the call that showed it.

What this session **saw**:
- This session's proxy refuses the environments API. `GET repos/staffLooper/ready-gate-lab/environments/staff-gate` and `…/deployment-branch-policies` returned HTTP 403, "Access to this GitHub API path is not permitted through this proxy". So E1 runs in CI.
- The lab is public. Its only ruleset is the organization's `worklist-protection` (27746484), which covers `refs/heads/worklist` only. Lab `main` has no protection.
- The lab's initial commit `01d62b6` already has one check suite, from the `claude` App (id 1236702), status `queued`.
- staffLooper/stafflooper is private, and its workflows already use an environment (`provision`, in `pave.yml`, `import.yml` and `island-consistency.yml`).

## The claims
| ID | What the design rests on | ADR-0082 | Source | Test |
|---|---|---|---|---|
| C0 | The gate App has exactly Checks and Commit statuses read and write, plus Contents, Pull requests and Metadata read. It is installed on one repository and subscribes to no webhook events | 2.1 | the ADR's own requirement | E0 |
| C1 | `staff-gate` reads back as `deployment_branch_policy` = `{"protected_branches": false, "custom_branch_policies": true}`, with exactly one policy, of type `branch`, named for the default branch | 2.2 | relayed (response shape) | E1.1 |
| C1b | A job that names a missing environment makes GitHub create it with no branch rule | 2.2 (Red Team N3) | relayed | E1.2 |
| C2 | A workflow on a pushed branch can't read `STAFF_GATE_PRIVATE_KEY` | 2.2 (Red Team N12) | relayed | E2.1 |
| C3 | Neither the `pull_request` nor the `pull_request_target` run of a pull request into a non-default base can read it | 2.2 (Red Team N8, N12) | relayed | E2.2 |
| C3b | A retarget to the default branch fires `edited` with `changes.base` | 2.2 (Red Team round 2 N5) | relayed | E2.2c |
| C3c | Neither a `pull_request` workflow that a pull request into `main` adds, nor a pushed tag named `main`, can read the key. No repository or organization secret has the key's name | 2.2 | mine (added cases) | E2.3, E2.4, every E2 run |
| C4 | Only the App that created a check run can update it. Another App can create one with the same name and `external_id` | 3.5 (Red Team round 4 B1) | relayed | E3.1 |
| C5 | No API call deletes a check run or suite, and deleting the Actions run that wrote an entry leaves the entry | 3.5 | relayed (the first half) and mine (the second) | E3.2 |
| C6 | A check run's output summary holds up to 65,535 characters | 3.5 (Red Team round 4 N3) | relayed | E3.3 |
| C7 | Check runs on the ledger commit don't show on a pull request | 3.5 | relayed | E3.4 |
| C8 | A check run or status can be read right after it's written (read-after-write) | 3.5 (Red Team round 3 N1; round 2 N1) | not stated anywhere; measured | E3.5 |
| C9 | Re-requesting a check run resets it to queued with no conclusion. Does its output survive? | 3.5 (Red Team round 4 B3; round 5 N1) | relayed. Mine: GitHub's docs say the run's **suite** resets and the run itself doesn't | E3.6 |
| C10 | Re-requesting a suite resets it to queued with no conclusion | 3.5 (Red Team round 4 B3) | relayed | E3.6 |
| C11 | Once a commit has more than about 1,000 check suites, the list-for-ref read drops the oldest, and a new write may not bring an entry back | 3.5 (Red Team round 4 B2; round 5 B2) | relayed | E3.7 |
| C12 | `check_name` matches exactly, and `app_id` filters by creator | 3.5 (Red Team round 4 N5, B1) | relayed | E3.1 |
| C13 | At most 1,000 statuses per commit and context, whoever creates them. After a fill, the gate App can't write `ready` | R10 (Red Team N1) | relayed | E4 |
| C14 | In a concurrency group with `cancel-in-progress: false`, one run runs and one waits. A newer waiting run replaces the older one, and that older run's event payload is lost unless something outside the group recorded it. **How often, and in which setups?** | 5.2, 3.5 (`ingest`); Red Team round 1 N6, round 2 B1; the question the brief relays as round 5's | relayed (the rule); the rate is unmeasured | E5 |
| C15 | A `workflow_run` event carries its pull request's number, so `ready-<number>` groups it right | 5.1, 5.2 | mine (a question: `pull_requests` may be empty for `pull_request_target` runs) | E5 |
| C16 | Check runs persist (round 4's residual: garbage collection) | 3.5 | unknown; 30 days can only bound it | E3.8 |

## What the sponsor must create first
These are his: Apps and keys are his accounts and credentials (ADR-0064 decision 1). No session asks for, sees or handles the key. About 15 minutes. All of it is two-way: deleting the App revokes its key, and environments can be deleted.

1. **Create a lab gate App.** Use a lab App, not `stafflooper-gate`: D4 gives each repository its own App (proposal Q1). Go to https://github.com/organizations/staffLooper/settings/apps/new.
   - GitHub App name: `staffLooper-ready-gate-lab` (any unused name works; the results show it).
   - Homepage URL: `https://github.com/staffLooper/ready-gate-lab`.
   - Webhook: untick **Active**.
   - Repository permissions:
     - **Checks:** Read and write;
     - **Commit statuses:** Read and write;
     - **Contents:** Read-only;
     - **Pull requests:** Read-only;
     - **Metadata:** Read-only (GitHub sets it).
     Everything else stays **No access**, with no organization or account permissions.
   - Subscribe to events: none.
   - Where can this GitHub App be installed: **Only on this account**.
   - Select **Create GitHub App**, then note the **App ID** shown on the next page.
2. **Install it on the lab only.** On the App's page, open **Install App**, choose staffLooper, then **Only select repositories**, pick `ready-gate-lab` and select **Install**.
3. **Generate its private key.** On the App's page, under **Private keys**, select **Generate a private key**. The browser downloads a `.pem` file. Never paste it into a chat, an issue or a file in any repository.
4. **Create the `staff-gate` environment** at https://github.com/staffLooper/ready-gate-lab/settings/environments: select **New environment**, enter the name `staff-gate`, then **Configure environment**.
   - **Deployment branches and tags:** choose **Selected branches and tags**, then **Add deployment branch or tag rule**, with Ref type **Branch** and name pattern `main`. Add no other rule: no required reviewers and no wait timer.
   - **Environment secrets:** **Add environment secret** named `STAFF_GATE_PRIVATE_KEY`. Its value is the whole `.pem` file, opened in a text editor, BEGIN and END lines included.
   - **Environment variables:** **Add environment variable** named `STAFF_GATE_APP_ID`, whose value is the App ID from step 1.
   - Delete the downloaded `.pem`, and empty the trash.
5. **Create nothing else with that name.** Add no repository or organization secret called `STAFF_GATE_PRIVATE_KEY`: E2 checks that none exists.
6. **Merge this pull request.** That puts the workflows on `main`. The merge starts nothing: no workflow here triggers on a push to `main`. Later pull requests and comments that aren't `probe/*` or `[burst]` ones create only runs whose jobs are skipped.
7. **Give the go** for the session's acts listed under "Needs a human" (chat rule 6: dispatches need his go; rule 15(e): writes beyond its own branch and pull request aren't rated two-way).

The on-screen names are as the Architect recalls them (mine). If a screen differs, E0 and E1 read back what was made, so a wrong setting shows up as FAIL, not as a silent pass.

**Evidence it's done:** E0 PASS (the App) and E1.1 PASS (the environment).

## Setup (the session, after the merge and the go)
1. Create one branch per purpose, each with one empty commit on top of `main`. Each commit's full sha is a lab "ledger commit":
   - `lab/ledger-basic` (L-basic);
   - `lab/ledger-raw` (L-raw);
   - `lab/ledger-rr` (L-rr);
   - `lab/flood` (L-flood);
   - `lab/cap` (L-cap).
   Each step has its own commit, so a flood or a fill can't spoil another step's reading.
2. Create `lab/results` from `main`. Every CI step saves its output there through `scripts/save.sh`. github.token's pushes start no workflows, so saving triggers nothing.
3. Create `lab/base-x` from `main`, for E2.2.

## Rules for every run
- **No key is printed.** The probes print only `key_present=true|false`. `app-token.sh` masks the JWT and the token. It writes the token only to `$RUNNER_TEMP/gate-token`, mode 600, and deletes the key file once the JWT is signed. `app.json` keeps the token's permissions and expiry, never the token.
- **Only jobs on `main` name `staff-gate`, and only `workflow_dispatch` starts them.** The exceptions are E2's probes, whose job is to try. On `pull_request_target`, a probe that names the environment runs only for this repository's own `probe/*` branches, so a stranger's fork can't start one on this public repository.
- **Pacing.** The scripts back off on 403 and 429 and wait for the rate limit to reset. Mine, unchecked: github.token gets about 1,000 requests an hour per repository, and content-creating calls have a secondary limit of about 80 a minute. The long fills resume when dispatched again.
- **Output is pretty-printed JSON** (chat rule 13). Each step saves its calls (`calls.json`), what it read (`snapshots.json` or `rows.json`) and its readings (`verdicts.json`) under `runs/<step>/<run id>/` on `lab/results`. Each reading is one of:
  - PASS or FAIL against the claim;
  - MEASURED, with the number;
  - not measured, with the reason.
- **Nothing private reaches this public lab.** From stafflooper, only the counts in `history.json` (E5.4) come here.

## E0. The App reads back as created (C0)
- **Steps:** dispatch `lab-ledger.yml` with step `app-readback`.
- **Captured:** `runs/app-readback/<run>/app.json` holds:
  - the App: id, slug, owner, permissions, events;
  - the installation: id, `repository_selection`, permissions;
  - the token's permissions;
  - the repositories the token reaches.
- **Reading:**
  - E0.1 PASS when the owner is `staffLooper`;
  - E0.2 PASS when the installation's permissions are exactly `{"checks":"write","contents":"read","metadata":"read","pull_requests":"read","statuses":"write"}`;
  - E0.3 PASS when the selection is `selected` and the only repository is `staffLooper/ready-gate-lab`;
  - E0.4 PASS when the App subscribes to no events.
  Any FAIL means the sponsor fixes the App before anything else runs.

## E1. The environment reads back (C1, C1b)
- **E1.1 steps:** dispatch `lab-readback.yml` with step `staff-gate`. It reads the environment and its branch policies with github.token, then again with no token, from a job that names no environment.
- **E1.2 steps:** dispatch it with step `missing`. Its `touch` job names `lab-never-created`, then `readback` reads what GitHub made of it. Afterwards the sponsor deletes `lab-never-created` (cleanup).
- **Captured:** `runs/readback-staff-gate/…` and `runs/readback-missing/…`: every call, its HTTP status and its response.
- **Reading:**
  - **C1 PASS** when either caller reads HTTP 200 with exactly the shape in C1 and one policy, `{"type": "branch", "name": "main"}`. FAIL when it reads anything else.
  - If both callers are refused, C1 is **not measured** in CI, and that is a finding for chunk 9. The pave's read-back then needs a caller that can read environments, because a session's proxy can't (seen).
  - **C1b PASS** when `lab-never-created` exists after `touch` with `deployment_branch_policy` null. That confirms the read-back is needed.

## E2. The key stays on the default branch (C2, C3, C3b, C3c)
Each run of `lab-key-probe.yml` (or of `lab-pr-probe.yml` in E2.3) has three jobs:
- `with-environment` names `staff-gate`;
- `without-environment` names none;
- `record` reads the run's jobs, their annotations and logs, and the `staff-gate` deployments, then saves `runs/e2/<event>-<ref>/<run>/`.

| Case | Session's steps | Expected (the reading) |
|---|---|---|
| **E2.0** control | Dispatch `lab-key-probe.yml` on `main` | `key_present=true`. If this fails, nothing below proves anything |
| **E2.1** pushed branch | Push `probe/pushed` (`main` plus one empty commit). Its `push` run uses the branch's own file | `with-environment` refused before any step, no `key_present=true`, with the refusal in its annotations |
| **E2.1b** dispatch on a branch (mine) | Dispatch `lab-key-probe.yml` on ref `probe/pushed` | Refused |
| **E2.2** pull request into a non-default base | Push `probe/stacked` (`lab/base-x` plus one empty commit). Open a pull request from it into `lab/base-x`. That starts a `pull_request` run (on `refs/pull/N/merge`) and a `pull_request_target` run (on `lab/base-x`) | Both refused |
| **E2.2c** retarget | Change that pull request's base to `main` (`PATCH pulls/N`, `base=main`) | MEASURED: `event.json` shows `action: edited` and `changes.base`. The `pull_request_target` run on `main` is **admitted, by design**: it's how `start` and `decide` reach the key (ADR-0082 decision 2.2). Then close the pull request |
| **E2.3** pull request into `main` that adds a workflow (mine) | Push `probe/pr-into-main` with `probes/pr-probe.yml` copied to `.github/workflows/lab-pr-probe.yml`. Open a draft pull request into `main` | `lab-pr-probe` (`pull_request`, on `refs/pull/N/merge`) refused. `lab-key-probe`'s `pull_request_target` run on `main` is admitted, by design, and recorded as what a pull request into `main` can start. Close without merging |
| **E2.4** tag named `main` (mine) | Push tag `main` at `probe/pushed`'s commit, then delete it at once | Refused (the policy is of type `branch`) |

In every case, `without-environment` must show `key_present=false`.

- **Reading:** chunk 0's boundary proof (ADR-0082 decision 2.2, practice 3.8) passes when E2.0 passes, every refusal passes and every `without-environment` reads false. Any `key_present=true` off `main` is a FAIL that stops the build: decision 2.2 rests on it.
- **Clean up:** the session deletes the `probe/*` branches and the tag.

## E3. The check-run ledger (C4 to C12, C16)
All E3 steps dispatch `lab-ledger.yml`. "gate" means the lab App's token. "github.token" stands in for any other App, such as a branch workflow.

**E3.1 and E3.2, ownership and no delete (C4, C5, C12)**
- **Steps:** step `ownership`, `sha` = L-basic. In order:
  1. gate creates A: `ready pr-1`, `block:red-team:r1`, `failure`;
  2. github.token tries to update A;
  3. gate updates A;
  4. github.token creates B: same name, `external_id` `accept:000…`;
  5. gate tries to update B;
  6. both callers try `DELETE` on A and on A's suite, then A is read again;
  7. gate creates `ready pr-4` and `ready pr-41`, and the ledger read runs by name and by `app_id`.
  Then step `delete-run`, with `target_run` set to the ownership run's id and `check_run` set to A's id (from `check-run-A.txt`). It deletes that Actions run and reads A again.
- **Session's half:** run `scripts/user-probe.sh <A> <A's suite>` from the session. It tries to update, delete and re-request with the session's own login, and saves `user-probe.json`. A proxy refusal counts as "not measured".
- **Reading:**
  - **C4 PASS** when github.token's update is refused and A stays `failure`, gate's update of A succeeds, and gate's update of B is refused;
  - **C4b MEASURED:** whether github.token can create B, which is round 4 B1's premise;
  - **C5 PASS** when all four deletes are refused and A still reads 200. **C5b PASS** when A survives the deleted Actions run;
  - **C12a PASS** when `ready pr-4` returns only `ready pr-4`. **C12b PASS** when the `app_id` read returns only gate entries.

**E3.3, output size (C6)**
- **Steps:** step `output-limit`, on L-basic. Gate creates summaries of:
  - 65,535 and 65,536 ASCII characters;
  - 32,767, 32,768 and 65,535 two-byte characters (`é`).
- **Reading:**
  - **C6 PASS** when 65,535 ASCII characters are stored whole and 65,536 are refused;
  - **C6b MEASURED:** whether the limit counts characters or bytes. If it counts bytes, decision 3.5's 60,000-character cut doesn't fit non-ASCII text.

**E3.4, not on a pull request (C7)**
- **Steps:** push `lab/vis` (`main` plus one empty commit) and open a draft pull request into `main`. Then run step `visibility`, with `sha` = L-basic and `pr_head` set to that pull request's head sha.
- **Reading:** **C7 PASS** when the pull request's head has no `ready pr-*` check run.

**E3.5, read-after-write (C8)**
- **Steps:** step `read-after-write`, on L-raw, `n` = 100. Each round:
  1. gate creates `raw-<i>`;
  2. the ledger reads it at once, by list and by id;
  3. gate completes it as `success`, and it is read again;
  4. gate posts status `raw/<i>`, and the statuses list is read.
  A miss is polled every 250 ms for up to 30 s.
- **Captured:** `raw.json`: for each round and each kind, whether the first read saw it and how many milliseconds until it did.
- **Reading:** **C8 PASS** when all 100 rounds are visible on the first read, for all four kinds. Otherwise it is MEASURED, with the miss count and the worst lag, and the design round adds a retry rule.

**E3.6, re-request (C9, C10)**
- **Steps:** step `rerequest`, on L-rr.
  1. Gate creates R1 (`failure`, with a JSON summary) and R2 (`neutral`), both in one suite.
  2. github.token re-requests R1. Then gate re-requests R1.
  3. github.token re-requests the suite. Then gate re-requests the suite.
  After each re-request, the step:
  - snapshots R1, R2 and the suite: status, conclusion, `completed_at` and the summary's sha256;
  - runs the ledger read;
  - repairs any entry that changed, as decision 3.5 says, and snapshots again.
  The session then runs `user-probe.sh` on R1 and the suite.
- **Reading:**
  - **C9-C10 MEASURED:** which fields changed, for each caller and each kind of re-request;
  - **C9a PASS** when R1's summary hash is the same in every snapshot. FAIL confirms round 5 N1: a re-request can lose the entry's JSON;
  - **C9b PASS** when gate's repair brings R1 back to `completed/failure`.

**E3.7, the 1,000-suite cut (C11)**
- **Steps:**
  1. Step `flood-seed` on L-flood: gate writes `genesis`, a block and an accept under `ready pr-1`.
  2. Dispatch `lab-fill.yml` with step `flood`, `sha` = L-flood and `app_id` from E0. It dispatches `lab-flood.yml` on `lab/flood` in batches. Mine, unchecked: github.token may start `workflow_dispatch` runs, and each run adds one check suite. The script counts suites, so it measures that too.
  3. At each checkpoint (500, 990, 1,000, 1,010, 1,100 and 1,300 suites), the fill runs these reads:
     - (a) ADR-0082's list-for-ref read with `app_id`;
     - (b) the same read without `app_id`;
     - (c) the gate App's suites for the ref;
     - (d) the runs inside the gate suite;
     - (e) the commit's total of all check runs.
  4. Step `flood-after`: gate writes one more entry, and the reads run again.
- **Fallback:** if github.token's dispatches add no suites, the fill stops with that reading after 3 stalled batches. The session then dispatches `lab-flood.yml` from its own machine in batches of 25, and runs `lab-fill` again.
- **Reading:**
  - **C11 MEASURED:** the first checkpoint at which read (a) returns fewer than the 3 seeded entries ("none" if none does);
  - whether (d) still finds them, which would be a read path that the cut doesn't reach;
  - **C11-after:** whether a new write brings the suite back (4 entries) or not (round 5 B2's "the new `genesis` may stay invisible").

**E3.8, still there later (C16)**
- **Steps:** at 7 days and at 30 days, run step `gc-reread`, with `app_id`, for each of L-basic, L-rr and L-flood.
- **Reading:** MEASURED, the entry counts compared with the first reads. This bounds garbage collection over 30 days. It can't rule it out.

## E4. The status cap (C13)
- **Steps:**
  1. Dispatch `lab-fill.yml` with step `cap` and `sha` = L-cap. github.token posts `ready` statuses until GitHub refuses one, or for 1,005 attempts. It resumes from the count already there.
  2. Dispatch `lab-ledger.yml` with step `cap-gate` on L-cap. Gate posts `ready`, then `ready-other`, and the combined status is read.
- **Reading:**
  - **C13 PASS** when exactly 1,000 statuses are accepted and attempt 1,001 gets 422;
  - **C13b PASS** when gate is then refused `ready` but can write `ready-other`. That means R10's case stands, and break-glass is the only way out. Otherwise it is MEASURED.

## E5. Replaced runs and lost payloads (C14, C15)
Four workflows run on every event of a pull request whose title starts `[burst]`. None needs a secret.

| Setup | Shape | Why |
|---|---|---|
| **A** | `ingest` in its own group per run, then `evaluate` in the job-level group `lab-a-<pr>`, `cancel-in-progress: false`. Also runs on `workflow_run` of D | ADR-0082 decisions 3.5 and 5.2, as merged |
| **B** | One job in a workflow-level group `lab-b-<pr>`, `cancel-in-progress: false`, with the payload handled inside the group. Also runs on `workflow_run` of D | The shape Red Team round 2 B1 found loses payloads |
| **C** | One job in the job-level group `lab-c-<pr>`, `cancel-in-progress: true` | Contrast: running jobs cancelled too |
| **D** | No group | Control: nothing cancelled. Its completion is the `workflow_run` event, as `staff-review` is for `ready.yml` |

Each evaluation holds its group for `EVAL_SECONDS` = 20, a guess: the real `evaluate` hasn't been built. Each job's name carries its group key, so the report can see which group a run joined.

- **Steps:**
  1. Push `lab/burst` (`main` plus one empty commit), and open a pull request into `main` titled `[burst] concurrency probe`. It is never merged.
  2. Note the time, then run `scripts/burst.sh <pr> <clone of the lab on lab/burst>` from the session.
     - It sends 3 mixes, each of 3 events: three comments; a push then two comments; and label, unlabel, comment.
     - Each mix runs at 4 spacings (0, 2, 5 and 15 s), 5 times over.
     - That makes 60 bursts and 180 events, with 120 s between bursts. It takes about 2.5 hours.
     - The session's own login sends them, because github.token's events start no workflows (mine, unchecked).
     - It commits `runs/e5/burst-log.json` to `lab/results`.
  3. Dispatch `lab-conc-report.yml` with `since` set to the noted time. It joins each run to its burst and saves `runs/e5/report/<run>/report.json`.
  4. **E5.4, real history:** run `scripts/history.sh 30` from the session. It reads stafflooper's Actions runs from the last 30 days and writes counts only: per workflow, the cancelled runs, by event. Commit it as `runs/e5/history.json`. A cancel there can have other causes (`cancel-in-progress`, a manual cancel), so it bounds the rate and doesn't measure it.
- **Reading:**
  - **C14-A PASS** when, in setup A, every `ingest` succeeded (no payload lost) and every burst's last event got an evaluation that started after its run was created. FAIL refutes decision 5.2's safety claim.
  - **C14-rule PASS** when, in A and B, no evaluation was cancelled after it started and no burst's newest run was cancelled, so the older waiting run is the one replaced. FAIL refutes the relayed rule.
  - **C14 MEASURED, the answer to "how often":** for each setup, mix and spacing, the evaluations cancelled and the payloads lost per event sent. B's lost payloads are the rate at which event data dies when the payload is handled inside the group. The history counts bound how often such bursts happen for real.
  - **C15 MEASURED:** the number of evaluations grouped as `none`. More than 0 means `workflow_run` evaluations can't find their pull request and share one group across pull requests: a finding for decision 5.2.

## Order, time and cost
| Order | What | Time (Architect's estimate) |
|---|---|---|
| 1 | The sponsor's steps 1 to 7 | about 15 min of his |
| 2 | Setup, then E0, E1 and E2 | about 1 h |
| 3 | E3.1 to E3.6 | about 1 h |
| 4 | E3.7 flood, and E4 cap, run one after the other because they share github.token's rate limit | 3 to 6 h elapsed, unattended |
| 5 | E5, on its own, so runner queues don't skew its timings | about 3 h |
| 6 | The results pull request (`lab/results` into `main`), for his merge | 30 min |
| 7 | E3.8, at 7 and at 30 days | minutes each |

About 1,300 flood runs and 1,100 E5 runs. Mine, unchecked: Actions minutes are free on public repositories.

**Cleanup, after the design round.** The sponsor deletes:
- the lab App, which revokes its key;
- the `staff-gate` and `lab-never-created` environments.

The session deletes the `lab/*` and `probe/*` branches.

## What this lab can't show
- **Public, not private.** stafflooper and the islands are private. Fork pull requests and outside comments exist here and not there. Whether branch policies behave the same on a private repository on staffLooper's plan isn't measured here; stafflooper's `provision` environment shows that environments work there (seen).
- **Lab `main` is unprotected** (seen). E2 proves the branch rule. It says nothing about who can change `main`, which stafflooper's `protect-main` ruleset covers.
- **A lab App,** not `stafflooper-gate` (D4). Behaviour per App should carry over; permissions are read back again at the real bootstrapping.
- **The UI.** E3.6 re-requests through the API only. A "Re-run" button on the checks page isn't tested.
- **E5's timings** depend on runner queues and on the 20-second guess.
- **A point in time.** GitHub can change any of this. The results carry their dates.

## Questions for the sponsor
Each comes with the Architect's proposed answer, which the merge decides only if he lists it (AGENTS.md rule 5).
- **Q1. A separate lab App?** Proposed: yes, `staffLooper-ready-gate-lab`, deleted after the design round. Under D4, `stafflooper-gate` must be installed on stafflooper only.
- **Q2. Does stafflooper's own chunk 0 bootstrapping wait until after the design round?** That means `stafflooper-gate`, its environment and read-back, the ledger sha and App id in desired state, and the practice 6.3 sponsor-task issue. Proposed: yes. The design round may change what the App needs.
- **Q3. Can results go in this public lab?** That means lab data, and counts only from stafflooper. Proposed: yes.

## Verdict (ADR-0019)
This plan works when every claim C0 to C16 has a committed reading on `lab/results`: PASS, FAIL, MEASURED with its number, or not measured with its reason. Each reading points to the captured output it came from. The design round then cites these files, not recollections of GitHub's docs.

## Files
| File | What it does | Runs where |
|---|---|---|
| `.github/workflows/lab-readback.yml`, `scripts/readback.sh` | E1 | CI, no environment |
| `.github/workflows/lab-key-probe.yml`, `probes/pr-probe.yml`, `scripts/probe-record.sh` | E2 | CI; `pr-probe.yml` only on `probe/pr-into-main` |
| `.github/workflows/lab-ledger.yml`, `scripts/ledger.sh`, `scripts/app-token.sh` | E0, E3 and E4's gate half | CI; job `gate` names `staff-gate` |
| `.github/workflows/lab-fill.yml`, `.github/workflows/lab-flood.yml`, `scripts/fill.sh` | E3.7, E4 | CI, github.token only |
| `.github/workflows/lab-conc-{a,b,c,d}.yml`, `.github/workflows/lab-conc-report.yml`, `scripts/conc-report.sh` | E5 | CI, no secrets |
| `scripts/burst.sh`, `scripts/history.sh`, `scripts/user-probe.sh` | E5's events, E5.4, the user-token half of E3 | the session's machine |
| `scripts/lib.sh`, `scripts/save.sh` | shared: logged calls, readings, saving to `lab/results` | CI |

Checked before this pull request: every YAML file parses, every script passes `bash -n`, and the logging and E5 aggregation jq ran against small local fixtures. Nothing was run against GitHub with any credential.
