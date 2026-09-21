---
name: commit-push-pr
description: Land a finished piece of work on GitHub cleanly - commit what changed, push it on a feature branch, and open a pull request with a message that explains what changed and why (not just which files moved). Use this at the end of a working round, when a feature or bugfix has been built and validated, or when the user says things like "let's wrap this up", "commit and push", "open a PR", "land this", or "finish this feature". If there's nothing uncommitted but there are commits ahead of origin, it still pushes and opens the PR.
---

# Commit, push, and open a PR

Use this to close out a finished unit of work - a completed feature, a validated bugfix, a finished round of changes - so it lands on GitHub with a trail a reviewer (including future-you, or future-Claude in a later session with no memory of this one) can actually follow. Even for solo projects, a branch + PR beats pushing straight to master: it gives every round of work a reviewable diff and a description of *why*, not just *what*.

## Before doing anything: look, don't assume

Run `git status` and `git diff` (both staged and unstaged) first. Read what actually changed - don't write the commit message from memory of what you *meant* to do this round. If something unexpected shows up (a file you don't recognize, something that looks like scratch output, credentials, or personal data that shouldn't be tracked), stop and ask rather than committing it. This project in particular treats scan output (`output/`) as sensitive - it contains real file paths from the user's PC - so double-check nothing like that snuck past `.gitignore` before staging.

If there's nothing changed and nothing ahead of origin, say so plainly and stop - don't invent a commit.

## Steps

1. **Check the branch.** If currently on `master` or `main`, create a new branch first, named for what the work actually is (e.g. `treemap-and-longpath-fix`, not `update` or a timestamp). If already on a feature branch, keep using it.
2. **Stage deliberately.** Review `git status` before `git add -A` - if there's anything that shouldn't be there, exclude it explicitly rather than committing everything blindly.
3. **Write a commit message that explains the *why*, not just the *what*.** Look at how this project's earlier commits are written (`git log`) as the model: lead with a summary line, then bullet what changed, why it mattered, and - if the work was validated - how (a specific test, a real repro case, numbers before/after). "Fixed bug" tells a reviewer nothing; "the comma-joined -DriveLetters arg silently became one malformed token when invoked via `powershell -File`, crashing Get-Volume" tells them everything they need to trust the fix without re-deriving it.
4. **Push the branch** to origin.
5. **Open the PR** with `gh pr create`, base branch `master` (or whatever the repo's default is - check with `gh repo view --json defaultBranchRef` if unsure). Title = the commit's summary line; body = the fuller explanation, formatted so a human skimming it on GitHub gets the same understanding as someone reading the commit body.
6. **Attach this session to the PR.** The app's PR bar normally picks up a PR opened from this session automatically. Confirm with `mcp__ccd_pr__get_status` (session_id "self"); if it doesn't show the PR just opened, bind it explicitly with `mcp__ccd_pr__bind_pr` using the PR's URL. This is what lets the app track CI status and offer auto-fix against this same session later, instead of the link back to the work getting lost.
7. **Report the PR URL** back to the user plainly. Don't merge it yourself unless explicitly asked - opening it for review is the point.

## If `gh` isn't set up

If `gh auth status` shows not logged in, or `gh` isn't installed at all, say so clearly and stop rather than falling back to a plain `git push` and pretending the PR step happened. Landing on GitHub properly is the actual point of this skill.

## Don't

- Don't force-push.
- Don't skip commit hooks (`--no-verify`) to get past a failure - fix what's failing.
- Don't merge the PR yourself unless the user asks.
- Don't write a commit/PR message that's just a list of filenames. If you can't explain *why* a change happened in one sentence, go back and figure out why before writing the message.
