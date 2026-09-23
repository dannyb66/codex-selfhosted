#!/usr/bin/env bash
# aws-mfa.sh — obtain an MFA-elevated AWS session for codex-selfhosted, per account.
# SOURCE it (not execute) so the exported creds land in your shell too:
#   source ./aws-mfa.sh            # prompts for the 6-digit MFA code
#   source ./aws-mfa.sh 123456     # uses the provided code
#   CODEX_ENV=prod source ./aws-mfa.sh 123456
#
# Config: $CODEX_SELFHOSTED_CONFIG or ~/.config/codex-selfhosted/${CODEX_ENV:-default}.env
#   Required: AWS_PROFILE  AWS_REGION
#   Optional: AWS_ACCOUNT_ID (else derived from the profile's caller identity)
# Side effect: writes /tmp/mfa-env-${CODEX_ENV}.sh (chmod 600) with only AWS_* creds — the
# codex-selfhosted client re-sources it. No app secrets are fetched or stored.

CODEX_ENV="${CODEX_ENV:-default}"
_CFG="${CODEX_SELFHOSTED_CONFIG:-$HOME/.config/codex-selfhosted/$CODEX_ENV.env}"
[ -f "$_CFG" ] && . "$_CFG"

: "${AWS_PROFILE:?set AWS_PROFILE (in $_CFG)}"
: "${AWS_REGION:?set AWS_REGION (in $_CFG)}"

if [[ -n "${1:-}" ]]; then TOKEN="$1"; else echo -n "Enter 6-digit MFA code: "; read -r TOKEN; fi
if [[ ! "$TOKEN" =~ ^[0-9]{6}$ ]]; then echo "Error: MFA code must be exactly 6 digits."; return 1 2>/dev/null || exit 1; fi

# Derive the account id from the profile if not configured.
if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
  AWS_ACCOUNT_ID=$(aws --profile "$AWS_PROFILE" sts get-caller-identity --query Account --output text 2>/dev/null)
  AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID//$'\r'/}"
fi
[[ -z "$AWS_ACCOUNT_ID" || "$AWS_ACCOUNT_ID" == "None" ]] && { echo "Error: could not determine AWS_ACCOUNT_ID for profile '$AWS_PROFILE'."; return 1 2>/dev/null || exit 1; }

# Discover the caller's OWN virtual MFA device (works for whoever's signed in on this profile).
MFA_ARN=$(aws --profile "$AWS_PROFILE" iam list-mfa-devices \
  --query "MFADevices[?starts_with(SerialNumber, 'arn:aws:iam::${AWS_ACCOUNT_ID}:mfa/')].SerialNumber | [0]" \
  --output text 2>/dev/null)
MFA_ARN="${MFA_ARN//$'\r'/}"
if [[ -z "$MFA_ARN" || "$MFA_ARN" == "None" ]]; then
  echo "Error: no virtual MFA device found for profile '$AWS_PROFILE' (account $AWS_ACCOUNT_ID)."
  echo "Register one (not a U2F/security key) in IAM, then retry."
  return 1 2>/dev/null || exit 1
fi

# --query/--output text rather than jq (jq isn't on a stock Windows box; the CLI extracts fine).
CREDS=$(aws --profile "$AWS_PROFILE" sts get-session-token \
  --serial-number "$MFA_ARN" --token-code "$TOKEN" --duration-seconds 43200 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken,Expiration]' --output text 2>&1)
STS_STATUS=$?; CREDS="${CREDS//$'\r'/}"
if [[ $STS_STATUS -ne 0 || -z "$CREDS" ]]; then echo "Error: failed to obtain MFA session."; echo "$CREDS"; return 1 2>/dev/null || exit 1; fi

IFS=$'\t' read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN EXPIRATION <<< "$CREDS"
if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_SESSION_TOKEN" ]]; then
  echo "Error: unexpected response from sts get-session-token."; echo "$CREDS"; return 1 2>/dev/null || exit 1
fi

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION

_OUT="/tmp/mfa-env-$CODEX_ENV.sh"
umask 077
cat > "$_OUT" <<EOF
export AWS_ACCESS_KEY_ID=$(printf '%q' "$AWS_ACCESS_KEY_ID")
export AWS_SECRET_ACCESS_KEY=$(printf '%q' "$AWS_SECRET_ACCESS_KEY")
export AWS_SESSION_TOKEN=$(printf '%q' "$AWS_SESSION_TOKEN")
export AWS_REGION=$(printf '%q' "$AWS_REGION")
EOF
chmod 600 "$_OUT"
echo "MFA session active until $EXPIRATION UTC (env=$CODEX_ENV, account $AWS_ACCOUNT_ID)"
echo "$_OUT written (AWS_* only)"
unset _CFG _OUT TOKEN CREDS STS_STATUS MFA_ARN
