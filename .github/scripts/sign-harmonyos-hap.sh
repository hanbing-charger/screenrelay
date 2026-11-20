#!/usr/bin/env bash
set -euo pipefail
umask 077

required=(
  HARMONY_KEYSTORE_BASE64 HARMONY_CERTIFICATE_BASE64 HARMONY_PROFILE_BASE64
  HARMONY_KEY_ALIAS HARMONY_KEYSTORE_PASSWORD
)
if [[ ${HARMONY_REPO_PRIVATE:-false} != true ]]; then
  required+=(HARMONY_ARTIFACT_PASSWORD)
fi

missing=0
for name in "${required[@]}"; do
  if [[ -z ${!name:-} ]]; then
    echo "::error::Missing GitHub Actions secret: $name"
    missing=1
  fi
done
if ((missing)); then exit 1; fi
if [[ ${1:-} == --check ]]; then exit 0; fi

input_hap=${1:?Pass the unsigned HAP path}
sign_tool=${DEVECO_SIGN_TOOL:?DevEco signing tool path is required}
if [[ ! -s "$input_hap" || ! -r "$sign_tool" ]]; then
  echo "::error::Unsigned HAP or DevEco signing tool is missing."
  exit 1
fi

work_dir=$(mktemp -d "${RUNNER_TEMP:?}/harmony-sign.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

decode_material() {
  local name="$1" destination="$2"
  if ! printf '%s' "${!name}" | base64 --decode > "$destination" || [[ ! -s "$destination" ]]; then
    echo "::error::$name must contain the Base64 representation of the signing file."
    exit 1
  fi
}

decode_material HARMONY_KEYSTORE_BASE64 "$work_dir/key.p12"
decode_material HARMONY_CERTIFICATE_BASE64 "$work_dir/certificate.cer"
decode_material HARMONY_PROFILE_BASE64 "$work_dir/profile.p7b"

signed_name=screenrelay-harmonyos-signed.hap
signed_hap="$work_dir/$signed_name"
key_password=${HARMONY_KEY_PASSWORD:-$HARMONY_KEYSTORE_PASSWORD}
if ! java -jar "$sign_tool" sign-app \
  -mode localSign -signAlg SHA256withECDSA -signCode 1 \
  -keyAlias "$HARMONY_KEY_ALIAS" -keystoreFile "$work_dir/key.p12" \
  -keystorePwd "$HARMONY_KEYSTORE_PASSWORD" -keyPwd "$key_password" \
  -appCertFile "$work_dir/certificate.cer" -profileFile "$work_dir/profile.p7b" \
  -profileSigned 1 -inForm zip -inFile "$input_hap" -outFile "$signed_hap" \
  > "$work_dir/signer.log" 2>&1 || [[ ! -s "$signed_hap" ]]; then
  echo "::error::Huawei signing failed. Check the key alias, passwords, certificate and debug Profile."
  exit 1
fi

if ! java -jar "$sign_tool" verify-app \
  -inFile "$signed_hap" -inForm zip -outCertchain "$work_dir/certchain.cer" \
  -outProfile "$work_dir/verified-profile.p7b" > "$work_dir/verifier.log" 2>&1; then
  echo "::error::Huawei signature verification failed."
  exit 1
fi

artifact_dir=$(mktemp -d "$RUNNER_TEMP/harmony-artifact.XXXXXX")
if [[ ${HARMONY_REPO_PRIVATE:-false} == true ]]; then
  artifact_path="$artifact_dir/$signed_name"
  mv -- "$signed_hap" "$artifact_path"
else
  artifact_path="$artifact_dir/screenrelay-harmonyos-signed.7z"
  if ! command -v 7z >/dev/null; then
    echo "::error::7-Zip is required to protect signed packages in public repositories."
    exit 1
  fi
  if ! (cd "$work_dir" && 7z a -t7z -mhe=on -mx=0 \
    "-p$HARMONY_ARTIFACT_PASSWORD" "$artifact_path" "$signed_name") > "$work_dir/archive.log" 2>&1; then
    echo "::error::Could not encrypt the signed HAP artifact."
    exit 1
  fi
fi

test -s "$artifact_path"
printf 'artifact_path=%s\n' "$artifact_path" >> "${GITHUB_OUTPUT:?}"
echo "Huawei signature verified."
