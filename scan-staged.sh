#!/bin/bash
# scan-staged.sh: Scan staged diff for credential-shaped text.
#
# Scans STAGED changes (git diff --cached) of added lines only for patterns
# that match common credentials: AWS keys, GitHub tokens, OpenAI keys, Slack tokens,
# PEM private key headers, password/secret/api_key/token assignments with 8+ char values,
# and NNN-NN-NNNN number shapes (SSN-like).
#
# Exit codes:
#   0: No hits; prints "scan clean"
#   1: At least one hit; prints "SCAN HIT: <pattern>: <file>" (never prints the value)
#   2: Internal error (git failed, undefined variable, etc.)
#
# Environment:
#   SCAN_REPO_DIR (optional): Repo directory to scan. Defaults to current directory.
#

set -u

REPO_DIR="${SCAN_REPO_DIR:-.}"

# Verify git repo exists
if ! git -C "$REPO_DIR" rev-parse --git-dir > /dev/null 2>&1; then
  echo "SCAN ERROR: Not a git repository: $REPO_DIR" >&2
  exit 2
fi

# Get staged diff (added/modified lines only, no deleted)
DIFF_OUTPUT=$(git -C "$REPO_DIR" diff --cached --unified=0 2>&1)
DIFF_EXIT=$?

if [ $DIFF_EXIT -ne 0 ]; then
  echo "SCAN ERROR: git diff --cached failed" >&2
  exit 2
fi

# Track whether we found any hits
FOUND_HIT=0

# Parse the diff output. Format:
#   diff --git a/file b/file
#   index ...
#   --- a/file
#   +++ b/file
#   @@ -start,count +start,count @@
#   +added line here
#
# We extract the filename from the "+++" line and check added lines (starting with +).

CURRENT_FILE=""
while IFS= read -r line; do
  # Detect file name changes (from +++ lines in unified diff format)
  if [[ "$line" =~ ^\+\+\+\ b/(.*)$ ]]; then
    CURRENT_FILE="${BASH_REMATCH[1]}"
  fi

  # Only scan lines that were added (start with + but not +++)
  if [[ "$line" =~ ^\+ ]] && ! [[ "$line" =~ ^\+\+\+ ]]; then
    CONTENT="${line:1}"  # Strip the leading +

    # Pattern 1: AWS Access Key (AKIA followed by 16 alphanumeric)
    if [[ "$CONTENT" =~ AKIA[0-9A-Z]{16} ]]; then
      echo "SCAN HIT: AKIA: $CURRENT_FILE"
      FOUND_HIT=1
      continue
    fi

    # Pattern 2: GitHub token (ghp_ followed by 30+ chars)
    if [[ "$CONTENT" =~ g'hp_'[A-Za-z0-9]{30,} ]]; then
      echo "SCAN HIT: ghp_: $CURRENT_FILE"
      FOUND_HIT=1
      continue
    fi

    # Pattern 3: GitHub fine-grained access token prefix
    if [[ "$CONTENT" =~ github'_pat_' ]]; then
      echo "SCAN HIT: github-pat: $CURRENT_FILE"
      FOUND_HIT=1
      continue
    fi

    # Pattern 4: OpenAI key (sk- followed by 20+ chars of alphanumeric, underscore, dash)
    if [[ "$CONTENT" =~ s'k-'[A-Za-z0-9_-]{20,} ]]; then
      echo "SCAN HIT: sk-: $CURRENT_FILE"
      FOUND_HIT=1
      continue
    fi

    # Pattern 5: Slack token prefix (five letter variants)
    if [[ "$CONTENT" =~ xo'x'[baprs]'-' ]]; then
      echo "SCAN HIT: slack: $CURRENT_FILE"
      FOUND_HIT=1
      continue
    fi

    # Pattern 6: PEM Private Key header
    if [[ "$CONTENT" =~ BEGIN[\ ]+[A-Z\ ]*PRIVATE\ KEY ]]; then
      echo "SCAN HIT: PEM: $CURRENT_FILE"
      FOUND_HIT=1
      continue
    fi

    # Pattern 7: password/secret/api_key/token assignment (case-insensitive, =/:, optional quotes, 8+ chars)
    # Matches a name followed by an equals sign or colon, optional quotes, then a value.
    # For simplicity, we match any 8+ character non-whitespace value after = or :
    if [[ "$CONTENT" =~ [Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][[:space:]]*[:=][[:space:]]*[\"\']?[^[:space:]]{8,} ]] || \
       [[ "$CONTENT" =~ [Ss][Ee][Cc][Rr][Ee][Tt][[:space:]]*[:=][[:space:]]*[\"\']?[^[:space:]]{8,} ]] || \
       [[ "$CONTENT" =~ [Aa][Pp][Ii][_][Kk][Ee][Yy][[:space:]]*[:=][[:space:]]*[\"\']?[^[:space:]]{8,} ]] || \
       [[ "$CONTENT" =~ [Tt][Oo][Kk][Ee][Nn][[:space:]]*[:=][[:space:]]*[\"\']?[^[:space:]]{8,} ]]; then
      echo "SCAN HIT: assignment: $CURRENT_FILE"
      FOUND_HIT=1
      continue
    fi

    # Pattern 8: NNN-NN-NNNN (three digits, dash, two digits, dash, four digits)
    if [[ "$CONTENT" =~ [0-9]{3}-[0-9]{2}-[0-9]{4} ]]; then
      echo "SCAN HIT: NNN-NN-NNNN: $CURRENT_FILE"
      FOUND_HIT=1
      continue
    fi
  fi
done <<< "$DIFF_OUTPUT"

if [ $FOUND_HIT -eq 0 ]; then
  echo "scan clean"
  exit 0
else
  exit 1
fi
