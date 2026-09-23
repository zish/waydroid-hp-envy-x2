#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Refuse to push a branch containing an unsigned commit.
#
# WHY A SCRIPT AND NOT A GIT CONFIG SETTING
#
# `commit.gpgsign = true` signs what THIS clone creates and says nothing about
# what is already in the history -- a commit made with --no-gpg-sign, cherry-
# picked from elsewhere, or produced by a rebase that dropped signatures is
# still pushable. The invariant the project wants is about the branch, not
# about the act of committing, so it has to be checked at push time against
# the commits actually being sent.
#
# WHY %G? AND NOT `git verify-commit`
#
# verify-commit exits non-zero for both "bad signature" and "no signature" and
# prints gpg's output on stderr, so distinguishing the two means parsing gpg.
# %G? is a single character per commit, computed by the same code, and it
# separates every case we care about. The accepted set is G and U: both mean
# the signature verified. U only adds "the key is not marked trusted in this
# keyring", which is a property of the checking machine, not of the commit --
# failing on it would make the hook behave differently on a fresh clone.
# Everything else fails, including X and Y (expired key), because a signature
# that cannot be re-verified later is not much better than none.
#
# Usage:
#   bin/check-signed-commits.sh --pre-push        # read git's pre-push stdin
#   bin/check-signed-commits.sh --branch [<ref>]  # every commit reachable from
#                                                 # <ref> (default HEAD)
#   bin/check-signed-commits.sh --range <A>..<B>  # an explicit range
#
# Escape hatch, for the case where an unsigned commit genuinely has to go out:
#   ALLOW_UNSIGNED_PUSH=1 git push ...
# It is deliberately loud. There is no config setting for it, so it cannot be
# turned on once and forgotten.
#
# INSTALLING THE HOOK
#
# Hooks live in .git/, which is not version-controlled, so a fresh clone has no
# gate until somebody installs one. Either works, and lefthook is preferred
# once it is available:
#
#     lefthook install          # reaches this script via lefthook.yml
#
# or, with no lefthook, recreate the shim by hand:
#
#     printf '#!/bin/sh\nexec "$(git rev-parse --show-toplevel)/bin/%s" --pre-push\n' \
#         check-signed-commits.sh > .git/hooks/pre-push
#     chmod +x .git/hooks/pre-push
#
# `lefthook install` REPLACES that shim with its own dispatcher. The gate then
# depends on lefthook.yml being valid, so a syntax error there drops it
# silently -- run `lefthook run pre-push` once after installing to confirm.
set -eu

ZERO=0000000000000000000000000000000000000000

usage() {
	sed -n '/^# Usage:/,/^#   ALLOW/p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

# Report every commit in <range> whose signature is missing or unusable.
# Prints one line per offender and returns 1 if there were any.
check_range() {
	range=$1
	# Resolve the range first. Without this the pipeline below would take
	# awk's exit status, so a range git could not parse would report "no
	# unsigned commits" -- a check that passes because it never ran. The
	# return is 2 rather than 1 so the caller can tell "found unsigned
	# commits" from "could not run", and not offer advice about re-signing
	# history when the real problem is an unreadable range.
	if ! log=$(git log --format='%H %G? %an%x09%s' "$range" 2>&1); then
		echo "check-signed-commits: cannot read '$range': $log" >&2
		return 2
	fi
	bad=$(printf '%s\n' "$log" | awk '$2 != "G" && $2 != "U"')
	[ -n "$bad" ] || return 0

	printf '%s\n' "$bad" | while IFS=' ' read -r sha code rest; do
		case $code in
		N) why='no signature' ;;
		B) why='BAD signature' ;;
		E) why='signature cannot be checked (missing public key?)' ;;
		X) why='good signature, but the key has expired' ;;
		Y) why='good signature, made by a key that has since expired' ;;
		R) why='good signature, made by a REVOKED key' ;;
		*) why="unknown signature state '$code'" ;;
		esac
		printf '  %s  %s\n            %s\n' "$(echo "$sha" | cut -c1-12)" \
			"$rest" "$why"
	done
	return 1
}

mode=
ref=
range=
while [ $# -gt 0 ]; do
	case $1 in
	--pre-push) mode=prepush; shift ;;
	--branch)
		mode=branch
		shift
		ref=${1:-HEAD}
		if [ $# -gt 0 ]; then shift; fi
		;;
	--range) mode=range; shift; range=${1:?--range needs a revision range}; shift ;;
	-h | --help) usage ;;
	*) echo "unknown argument: $1" >&2; usage ;;
	esac
done
[ -n "$mode" ] || usage

if [ "${ALLOW_UNSIGNED_PUSH:-0}" != 0 ]; then
	echo "check-signed-commits: ALLOW_UNSIGNED_PUSH is set -- NOT checking signatures" >&2
	exit 0
fi

unsigned=0
failed=0

# Fold one check_range result into the two outcome flags. 1 is "found unsigned
# commits", 2 is "could not run", and they are reported differently.
tally() {
	case $1 in
	0) ;;
	1) unsigned=1 ;;
	*) failed=1 ;;
	esac
}

case $mode in
branch)
	check_range "$ref" && tally 0 || tally $?
	;;
range)
	check_range "$range" && tally 0 || tally $?
	;;
prepush)
	# git feeds one line per ref being pushed:
	#     <local ref> <local sha> <remote ref> <remote sha>
	while read -r _local_ref local_sha _remote_ref remote_sha; do
		# An all-zero local sha is a branch deletion: nothing to verify.
		[ "$local_sha" != "$ZERO" ] || continue

		# An all-zero remote sha means the branch is new on the remote. A
		# non-zero one we do not have locally means the same thing in
		# practice -- typically no fetch has ever run, which is exactly the
		# state a freshly configured origin is in. Either way, fall back to
		# every commit reachable from the tip, which is what "all commits in
		# the branch are signed" asks for anyway.
		if [ "$remote_sha" = "$ZERO" ] ||
			! git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
			check_range "$local_sha" && tally 0 || tally $?
		else
			check_range "${remote_sha}..${local_sha}" && tally 0 || tally $?
		fi
	done
	;;
esac

if [ "$unsigned" -ne 0 ]; then
	cat >&2 <<'EOF'

push refused: the commits above are not signed with a usable signature.

Fix the history rather than the hook. For the most recent commit:
    git commit --amend --no-edit -S
For a run of commits, re-sign them in place:
    git rebase --exec 'git commit --amend --no-edit -S' -i <base>

Signing is configured per clone; this one has commit.gpgsign and
user.signingkey set, so new commits are signed without asking.
EOF
fi
[ "$unsigned" -eq 0 ] && [ "$failed" -eq 0 ] || exit 1
exit 0
