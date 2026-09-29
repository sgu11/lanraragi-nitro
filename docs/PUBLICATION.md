# Public fork publication

The public fork is `sgu11/lanraragi-nitro`, branch `dev`. Prepare new public
changes from its currently published history in a separate, clean checkout.
Keep private deployment branches and operational records outside this history.

## After a public history cleanup

Refresh the public baseline before preparing another update. A clone made before
the cleanup can still contain removed information. Preserve unrelated local work
and use a fresh public clone, or deliberately rebase reviewed unpublished changes
onto the cleaned baseline. Do not merge the previous public history back into
`dev`; doing so makes the removed commits reachable again. Local rollback bundles
are private recovery material and must never be published as branches or tags.

## Before publishing

- Review the candidate tree and every newly exposed reachable commit, including
  historical file contents, paths, commit messages, and author/committer metadata.
- Use synthetic names and paths in privacy regression fixtures. Never hardcode
  actual personal values into a test that asserts those values are absent.
- Create new fork-owned commits with the public GitHub identity and verified
  GitHub noreply email. Verify both author and committer; preserve upstream credit.
- Check generated deliverables and run the checks appropriate to the actual diff.
- Recheck the remote branch before pushing. A rewritten history needs explicit
  authorization, a private rollback anchor, and an exact expected-SHA lease.

A cleaned branch does not remove existing third-party clones or GitHub's cached
views of old commit IDs. Report those exposure limits separately from branch
reachability; never claim that a successful push erased every existing copy.
