#!/usr/bin/env bash

# Publish the GitHub release for a pushed product tag. The annotated tag message,
# without its signature, becomes the release notes.
#
# RELEASE_LATEST controls the "Latest" badge:
#   highest - mark the release Latest only when its tag is the highest product version
#   never   - never mark the release Latest (legacy maintenance branches)

set -euo pipefail

tag="${GITHUB_REF_NAME:?Missing GITHUB_REF_NAME}"
repo="${GH_REPO:?Missing GH_REPO}"
policy="${RELEASE_LATEST:?Missing RELEASE_LATEST}"
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [[ "${GITHUB_REF:-}" != refs/tags/* || ! "${tag}" =~ ${semver} ]]; then
    echo >&2 "Refusing non-product release tag: ${tag}"
    exit 1
fi

# Re-running a tag build must not fail or overwrite notes edited by hand.
if gh release view "${tag}" --repo "${repo}" >/dev/null 2>&1; then
    echo "Release ${tag} already exists"
    exit 0
fi

ref=$(gh api "repos/${repo}/git/ref/tags/${tag}" --jq '.object.type + " " + .object.sha')
if [[ "${ref%% *}" != "tag" ]]; then
    echo >&2 "Tag ${tag} is not annotated; its message is the release notes"
    exit 1
fi

notes=$(mktemp)
trap 'rm -f "${notes}"' EXIT
gh api "repos/${repo}/git/tags/${ref#* }" --jq '.message' \
    | sed -E '/^-----BEGIN [A-Z ]*SIGNATURE-----$/,$d' > "${notes}"
if ! grep -q '[^[:space:]]' "${notes}"; then
    echo >&2 "Tag ${tag} has an empty message"
    exit 1
fi

case "${policy}" in
highest)
    highest=$(gh api --paginate "repos/${repo}/tags" --jq '.[].name' | grep -E "${semver}" | sort -V | tail -n 1)
    latest=$([[ "${tag}" == "${highest}" ]] && echo true || echo false)
    ;;
never)
    latest=false
    ;;
*)
    echo >&2 "Unknown RELEASE_LATEST: ${policy}"
    exit 1
    ;;
esac

gh release create "${tag}" --repo "${repo}" --verify-tag --title "${tag}" \
    --notes-file "${notes}" --latest="${latest}"
