#!/bin/bash
gh workflow run proptest-extra.yml \
  --ref ci/proptest-auto \
  --field base_ref=develop