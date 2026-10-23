# Copyright © 2026 Apple Inc. All Rights Reserved.

# APPLE INC.
# PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
# PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
# IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
# 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
# 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
# 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
# You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
# EA1937
# 10/02/2024

#!/usr/bin/env bash
#
# auto-update-dependencies.sh — Runs `swift package update` and opens (or
# refreshes) a single PR containing the resulting `Package.resolved` diff.
#
# Behavior:
#   - Always works on a fixed branch (BRANCH_NAME) and force-pushes it.
#   - If a PR for that branch is already open, refresh its title and body.
#   - Otherwise, open a new PR.
#   - If `swift package update` produces no diff, exit 0 silently and leave
#     any existing PR alone.
#
# Usage:
#   bash Scripts/auto-update-dependencies.sh
#
# Required environment:
#   RIO_NARRATIVE_CHAIN_PATH       Provided by Rio. Used by whisperctl to
#   RIO_NARRATIVE_PRIVATE_KEY_PATH  authenticate to Whisper and fetch the
#                                   bot's GitHub PAT.
#   SSH_AUTH_SOCK                  Required by `swift package update` to
#                                   fetch private SSH dependencies.
#
# Required tools (provided by aea-builder base image):
#   whisperctl, swift, git, python3
# Installed on demand:
#   gh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BRANCH_NAME="bot/auto-update-dependencies"
BASE_BRANCH="main"
BOT_GIT_NAME="Mirkwood Bot"
BOT_GIT_EMAIL="mirkwood_bot@apple.com"

WHISPER_NAMESPACE="mirkwood-data-plane"
WHISPER_BUCKET="aea-stream-downloader"
WHISPER_SECRET_NAME="mirkwood_bot-github-pie-personal-access-token"

# Step 0: Preconditions.
if [ -z "${RIO_NARRATIVE_CHAIN_PATH:-}" ] || [ -z "${RIO_NARRATIVE_PRIVATE_KEY_PATH:-}" ]; then
    echo "ERROR: RIO_NARRATIVE_CHAIN_PATH / RIO_NARRATIVE_PRIVATE_KEY_PATH must be set"
    exit 1
fi

# Step 1: Derive host and owner/repo from the origin remote URL.
ORIGIN_URL=$(git remote get-url origin)
case "$ORIGIN_URL" in
    git@*:*)
        rest="${ORIGIN_URL#git@}"
        GH_HOST_VALUE="${rest%%:*}"
        OWNER_REPO="${rest#*:}"
        OWNER_REPO="${OWNER_REPO%.git}"
        ;;
    https://*)
        rest="${ORIGIN_URL#https://}"
        GH_HOST_VALUE="${rest%%/*}"
        OWNER_REPO="${rest#*/}"
        OWNER_REPO="${OWNER_REPO%.git}"
        ;;
    *)
        echo "ERROR: Could not parse origin remote URL: $ORIGIN_URL"
        exit 1
        ;;
esac

echo "=== Target: $OWNER_REPO on $GH_HOST_VALUE ==="

# Step 2: Start from a clean copy of $BASE_BRANCH.
echo "=== Fetching origin/$BASE_BRANCH ==="
git fetch origin "$BASE_BRANCH"
git checkout -B "$BRANCH_NAME" "origin/$BASE_BRANCH"

# Step 3: Run the actual update.
echo "=== Running swift package update ==="
swift package update

# Step 4: If nothing changed, exit silently before doing any credential or
# network work.
if git diff --quiet -- Package.resolved; then
    echo "=== No dependency updates available — exiting ==="
    exit 0
fi

echo "=== Package.resolved has changes ==="

# Step 5: Set up cleanup for temp paths used past this point.
SECRETS_DIR=$(mktemp -d)
PR_BODY_FILE=$(mktemp)
OLD_RESOLVED=$(mktemp)
trap "rm -rf '$SECRETS_DIR' '$PR_BODY_FILE' '$OLD_RESOLVED'" EXIT

# Step 6: Fetch the GitHub PAT from Whisper.
echo "=== Fetching GitHub PAT from Whisper ==="
whisperctl secret fetch \
    --output-dir "$SECRETS_DIR" \
    --namespace "$WHISPER_NAMESPACE" \
    --buckets "$WHISPER_BUCKET" \
    --secret-name "$WHISPER_SECRET_NAME" \
    --client-certificate-format PEM \
    --client-certificate "$RIO_NARRATIVE_CHAIN_PATH" \
    --client-key "$RIO_NARRATIVE_PRIVATE_KEY_PATH"

GITHUB_TOKEN=$(cat "$SECRETS_DIR/$WHISPER_SECRET_NAME")
export GH_HOST="$GH_HOST_VALUE"
export GH_TOKEN="$GITHUB_TOKEN"

# Step 7: Install gh CLI if missing.
# UBI9 ships with dnf; the GitHub CLI repo is the upstream-supported install
# path. If this turns out flaky in CI, bake `gh` into Dockerfile.base.
if ! command -v gh >/dev/null 2>&1; then
    echo "=== Installing gh CLI ==="
    dnf install -y 'dnf-command(config-manager)'
    dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
    dnf install -y gh
fi

# Step 8: Build the PR body — a markdown table of version diffs derived from
# Package.resolved (JSON).
git show "origin/$BASE_BRANCH:Package.resolved" > "$OLD_RESOLVED"

python3 - "$OLD_RESOLVED" "$REPO_ROOT/Package.resolved" "$PR_BODY_FILE" <<'PYEOF'
import json
import sys

old_path, new_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

def load_pins(path):
    with open(path) as f:
        data = json.load(f)
    pins = {}
    for pin in data.get("pins", []):
        identity = pin.get("identity")
        state = pin.get("state", {})
        version = state.get("version") or state.get("revision", "?")[:12]
        pins[identity] = version
    return pins

old_pins = load_pins(old_path)
new_pins = load_pins(new_path)

changed, added, removed = [], [], []
for name in sorted(set(old_pins) | set(new_pins)):
    old_v, new_v = old_pins.get(name), new_pins.get(name)
    if old_v == new_v:
        continue
    if old_v is None:
        added.append((name, new_v))
    elif new_v is None:
        removed.append((name, old_v))
    else:
        changed.append((name, old_v, new_v))

with open(out_path, "w") as f:
    f.write("Opened automatically by the `auto-update-dependencies` pipeline.\n")
    f.write("Force-pushed weekly with the latest `swift package update` result.\n\n")
    if changed:
        f.write("## Updated\n\n")
        f.write("| Dependency | From | To |\n")
        f.write("| --- | --- | --- |\n")
        for name, old_v, new_v in changed:
            f.write(f"| `{name}` | `{old_v}` | `{new_v}` |\n")
        f.write("\n")
    if added:
        f.write("## Added\n\n")
        for name, new_v in added:
            f.write(f"- `{name}` @ `{new_v}`\n")
        f.write("\n")
    if removed:
        f.write("## Removed\n\n")
        for name, old_v in removed:
            f.write(f"- `{name}` (was `{old_v}`)\n")
        f.write("\n")
PYEOF

# Step 9: Commit on the bot's identity.
git config user.name "$BOT_GIT_NAME"
git config user.email "$BOT_GIT_EMAIL"
git add Package.resolved
TODAY=$(date -u +%F)
COMMIT_TITLE="chore: update Swift package dependencies ($TODAY)"
git commit -m "$COMMIT_TITLE"

# Step 10: Force-push to the fixed branch over HTTPS using the bot token. The
# branch is owned by this script; force-pushing is intentional.
echo "=== Pushing $BRANCH_NAME ==="
PUSH_URL="https://x-access-token:${GITHUB_TOKEN}@${GH_HOST_VALUE}/${OWNER_REPO}.git"
git push "$PUSH_URL" "HEAD:refs/heads/$BRANCH_NAME" --force

# Step 11: Open the PR if it doesn't exist, otherwise refresh title and body.
EXISTING_PR=$(gh pr list \
    --repo "$OWNER_REPO" \
    --head "$BRANCH_NAME" \
    --base "$BASE_BRANCH" \
    --state open \
    --json number \
    --jq '.[0].number // empty')

if [ -n "$EXISTING_PR" ]; then
    echo "=== Refreshing existing PR #$EXISTING_PR ==="
    gh pr edit "$EXISTING_PR" \
        --repo "$OWNER_REPO" \
        --title "$COMMIT_TITLE" \
        --body-file "$PR_BODY_FILE"
else
    echo "=== Creating new PR ==="
    gh pr create \
        --repo "$OWNER_REPO" \
        --base "$BASE_BRANCH" \
        --head "$BRANCH_NAME" \
        --title "$COMMIT_TITLE" \
        --body-file "$PR_BODY_FILE"
fi

echo "=== Done ==="
