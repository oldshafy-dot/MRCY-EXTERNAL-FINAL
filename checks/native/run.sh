#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output_dir="$(mktemp -d "${TMPDIR:-/tmp}/vita-native-checks.XXXXXX")"
trap 'rm -rf "$output_dir"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  ThreeOneOSFive/helpers/PatchProjectModels.swift \
  ThreeOneOSFive/helpers/PatchPayloadMerge.swift \
  ThreeOneOSFive/helpers/PatchTransaction.swift \
  ThreeOneOSFive/helpers/LicensingModels.swift \
  ThreeOneOSFive/helpers/SecureLicenseIdentity.swift \
  checks/native/RecoveryChecks.swift \
  -o "$output_dir/recovery-checks"
"$output_dir/recovery-checks"

swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  ThreeOneOSFive/helpers/PatchProjectModels.swift \
  ThreeOneOSFive/helpers/PatchPayloadMerge.swift \
  ThreeOneOSFive/helpers/PatchTransaction.swift \
  ThreeOneOSFive/helpers/PatchPackageCodec.swift \
  ThreeOneOSFive/helpers/PatchProjectLibrary.swift \
  checks/native/CatalogChecks.swift \
  -o "$output_dir/catalog-checks"
"$output_dir/catalog-checks"
