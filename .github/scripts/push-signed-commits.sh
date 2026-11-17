#!/usr/bin/env bash
# Publish the commits Upptime made in this job to the branch as signed commits.
#
# uptime-monitor commits with the git CLI and runs a bare `git push`. Those commits
# are unsigned, and `main` requires signed commits from everyone. The workflows
# therefore point the push URL of `origin` at a local bare repository (see the
# "Keep Upptime pushes local" step), so Upptime's own pushes stay on the runner.
# This script then replays every local commit through the GraphQL
# `createCommitOnBranch` mutation. Commits created that way by a GitHub App are
# signed by GitHub and show as Verified, so they pass the `required_signatures`
# rule. The App is the only bypass actor of the separate pull-request ruleset.
#
# Commit messages are kept as they are: the status page reads response times from
# the "... in 302 ms) [skip ci]" messages on history/<slug>.yml, and "[skip ci]"
# stops the push from triggering other workflows.
#
# Env:
#   BASE_SHA  commit the job checked out (set by the "Keep Upptime pushes local" step)
#   BRANCH    branch to publish to (the workflow's ref name)
#   GH_TOKEN  installation token of the Upptime GitHub App. When it is empty
#             (App not set up yet) the commits are pushed unsigned with plain git;
#             the active ruleset rejects that, so this is only a transition path.
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is not set}"
: "${BRANCH:?BRANCH is not set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
FETCH_URL="$(git remote get-url origin)"

if [ "$(git rev-parse HEAD)" = "$BASE_SHA" ]; then
  echo "No new commits to publish."
  exit 0
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::warning::Upptime GitHub App is not configured (vars.GH_APP_ID / secrets.GH_APP_PRIVATE_KEY); pushing unsigned commits with git."
  git pull --rebase "$FETCH_URL" "$BRANCH"
  git push "$FETCH_URL" "HEAD:refs/heads/$BRANCH"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Replays origin/$BRANCH..HEAD one commit at a time. Returns non-zero if the
# branch moved under us; the caller then rebases and tries again. Commits that
# were already published are dropped by the rebase (same patch upstream).
publish() {
  local head commit headline body
  head="$(git rev-parse "origin/$BRANCH")"
  for commit in $(git rev-list --reverse "origin/$BRANCH..HEAD"); do
    headline="$(git log -1 --format=%s "$commit")"
    body="$(git log -1 --format=%b "$commit")"

    printf '[]' > "$work/additions.json"
    printf '[]' > "$work/deletions.json"
    while IFS=$'\t' read -r status path; do
      if [ "$status" = "D" ]; then
        jq --arg path "$path" '. + [{path: $path}]' "$work/deletions.json" > "$work/tmp.json"
        mv "$work/tmp.json" "$work/deletions.json"
      else
        git show "$commit:$path" | base64 -w0 > "$work/content.b64"
        jq --arg path "$path" --rawfile contents "$work/content.b64" \
          '. + [{path: $path, contents: $contents}]' "$work/additions.json" > "$work/tmp.json"
        mv "$work/tmp.json" "$work/additions.json"
      fi
    done < <(git diff-tree --no-commit-id --no-renames -r --name-status "$commit^" "$commit")

    if [ "$(jq 'length' "$work/additions.json")" = 0 ] && [ "$(jq 'length' "$work/deletions.json")" = 0 ]; then
      echo "Skipping empty commit: $headline"
      continue
    fi

    jq -n \
      --arg repo "$REPO" --arg branch "$BRANCH" --arg head "$head" \
      --arg headline "$headline" --arg body "$body" \
      --slurpfile additions "$work/additions.json" \
      --slurpfile deletions "$work/deletions.json" \
      '{
        query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
        variables: {
          input: {
            branch: { repositoryNameWithOwner: $repo, branchName: $branch },
            expectedHeadOid: $head,
            message: ({ headline: $headline } + (if $body == "" then {} else { body: $body } end)),
            fileChanges: { additions: $additions[0], deletions: $deletions[0] }
          }
        }
      }' > "$work/request.json"

    if ! gh api graphql --input "$work/request.json" > "$work/response.json"; then
      cat "$work/response.json" >&2 || true
      return 1
    fi
    head="$(jq -r '.data.createCommitOnBranch.commit.oid' "$work/response.json")"
    echo "Published $head: $headline"
  done
}

for attempt in 1 2 3; do
  git fetch --quiet "$FETCH_URL" "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  git rebase --quiet "origin/$BRANCH"
  if publish; then
    exit 0
  fi
  echo "::warning::$BRANCH moved while publishing (attempt $attempt); rebasing and retrying."
done

echo "::error::Could not publish Upptime commits to $BRANCH after 3 attempts."
exit 1
