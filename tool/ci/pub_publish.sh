#!/usr/bin/env bash
# Publishes the package in the current directory to pub.dev with a GitHub
# OIDC token requested for this package alone (.github/workflows/publish.yml).
#
# setup-dart makes one token at the start of the job and registers it with
# `dart pub token add https://pub.dev --env-var PUB_TOKEN`; GitHub does not
# document how long an ID token lives (its example's exp is iat + 300 s),
# and the job publishes every package one after the other. A fresh token
# per package does not depend on that lifetime.
set -euo pipefail
token=$(curl -sSf \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https://pub.dev" | jq -r .value)
if [ -z "${token}" ] || [ "${token}" = "null" ]; then
  echo "::error::No OIDC token for pub.dev (does the job have id-token: write?)"
  exit 1
fi
echo "::add-mask::${token}"
PUB_TOKEN="${token}" dart pub publish --force
