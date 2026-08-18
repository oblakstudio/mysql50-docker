#!/usr/bin/env bash
set -Eeuo pipefail

WORKFLOW=".github/workflows/docker_build.yml"

build_inputs="$(awk '
    /^[[:space:]]*uses: docker\/build-push-action@v6$/ { in_step = 1; next }
    in_step && /^      - name:/ { exit }
    in_step { print }
' "$WORKFLOW")"

grep -Eq '^[[:space:]]*push:[[:space:]]*true$' <<<"$build_inputs"
grep -Eq '^[[:space:]]*platforms:[[:space:]]*linux/amd64,linux/386,linux/arm/v5$' <<<"$build_inputs"
grep -Eq '^[[:space:]]*provenance:[[:space:]]*mode=max$' <<<"$build_inputs"
grep -Eq '^[[:space:]]*sbom:[[:space:]]*true$' <<<"$build_inputs"

if grep -Eq '^[[:space:]]*(provenance|sbom):[[:space:]]*false$' "$WORKFLOW"; then
    echo "publishing workflow disables attestations" >&2
    exit 1
fi

grep -Fq 'uses: peter-evans/dockerhub-description@v4' "$WORKFLOW"
grep -Fq 'repository: ${{ env.REGISTRY_IMAGE }}' "$WORKFLOW"
grep -Fq 'readme-filepath: ./README.md' "$WORKFLOW"
grep -Fq 'SLSA provenance' README.md
grep -Fq 'SPDX SBOM' README.md
grep -Fq 'make publish-check' README.md

make_push="$(awk '
    /^push:/ { in_target = 1 }
    in_target && /^clean:/ { exit }
    in_target { print }
' Makefile)"
grep -Fq -- '--provenance=mode=max' <<<"$make_push"
grep -Fq -- '--sbom=true' <<<"$make_push"

echo "publishing workflow test passed"
