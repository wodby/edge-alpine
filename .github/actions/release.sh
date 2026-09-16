#!/usr/bin/env bash

set -euo pipefail

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
