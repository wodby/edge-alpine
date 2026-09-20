#!/usr/bin/env bash

set -euo pipefail

# Product releases use stable semantic versions. Keep the old r0 artifact, but
# reject new revision tags before authenticating or publishing anything.
if [[ "${GITHUB_REF}" == refs/tags/* && ! "${GITHUB_REF#refs/tags/}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo >&2 "Refusing non-product release tag: ${GITHUB_REF#refs/tags/}"
    exit 1
fi

if [[ "${GITHUB_REF}" == refs/heads/master || "${GITHUB_REF}" == refs/tags/* ]]; then
    printf '%s' "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin

    if [[ "${GITHUB_REF}" == refs/tags/* ]]; then
      export TAGS="${GITHUB_REF##*/}"
    fi

    IFS=',' read -ra tags <<< "${TAGS}"

    for tag in "${tags[@]}"; do
        # Retag the scanned image instead of rebuilding with --pull at release time.
        image=$(make --no-print-directory -s image-ref TAG="${tag}")
        docker tag "${SCANNED_IMAGE:?Missing scanned image}" "$image"
        make push TAG="${tag}"
    done
fi
