#!/bin/bash

usage () {
	echo "USAGE: ./sync-kernel.sh <libarena-repo> <kernel-repo> <bpf-branch>"
	echo ""
	echo "Set BPF_NEXT_BASELINE to override bpf-next tree commit, otherwise read from <libarena-repo>/CHECKPOINT-COMMIT."
	echo "Set BPF_BASELINE to override bpf tree commit, otherwise read from <libarena-repo>/BPF-CHECKPOINT-COMMIT."
	echo "Set MANUAL_MODE to 1 to manually control every cherry-picked commits."
	exit 1
}

set -eu

LIBARENA_REPO=${1-""}
LINUX_REPO=${2-""}
if [ -z "${LIBARENA_REPO}" ] || [ -z "${LINUX_REPO}" ]; then
	echo "Error: libarena or linux repos are not specified"
	usage
fi

BPF_BRANCH=${3-""}
if [ -z "${BPF_BRANCH}" ]; then
	echo "Error: linux's bpf tree branch is not specified"
	usage
fi

BASELINE_COMMIT=${BPF_NEXT_BASELINE:-$(cat ${LIBARENA_REPO}/CHECKPOINT-COMMIT)}
BPF_BASELINE_COMMIT=${BPF_BASELINE:-$(cat ${LIBARENA_REPO}/BPF-CHECKPOINT-COMMIT)}
if [ -z "${BASELINE_COMMIT}" ] || [ -z "${BPF_BASELINE_COMMIT}" ]; then
	echo "Error: bpf or bpf-next baseline commits are not provided"
	usage
fi

SUFFIX=$(date --utc +%Y-%m-%dT%H-%M-%S.%3NZ)
WORKDIR=$(pwd)
TMP_DIR=$(mktemp -d)

trap "cd ${WORKDIR}; exit" INT TERM EXIT

LIBARENA_KERNEL_PATH=tools/testing/selftests/bpf/libarena

declare -A PATH_MAP
PATH_MAP=( \
	[tools/testing/selftests/bpf/bpf_experimental.h]=include/bpf_experimental.h \
	[tools/testing/selftests/bpf/bpf_rand.h]=include/bpf_rand.h \
	[tools/testing/selftests/bpf/bpf_sockopt_helpers.h]=include/bpf_sockopt_helpers.h \
	[tools/testing/selftests/bpf/bpf_util.h]=include/bpf_util.h \
)

LIBARENA_PATHS=("${LIBARENA_KERNEL_PATH}" "${!PATH_MAP[@]}")

LIBARENA_TREE_FILTER="mkdir -p __libarena/include && cp -a ${LIBARENA_KERNEL_PATH}/. __libarena/ && "$'\\\n'
for p in "${!PATH_MAP[@]}"; do
	LIBARENA_TREE_FILTER+="cp -a ${p} __libarena/${PATH_MAP[${p}]} && "$'\\\n'
done
LIBARENA_TREE_FILTER+="true"

cd_workdir()
{
	cd ${WORKDIR} && cd "$1"
}

# Output brief single-line commit description
# $1 - commit ref
commit_desc()
{
	git log -n1 --pretty='%h ("%s")' $1
}

# Create commit single-line signature, which consists of:
# - full commit subject
# - author date in ISO8601 format
# - full commit body with newlines replaced with vertical bars (|)
# - shortstat appended at the end
# The idea is that this single-line signature is good enough to make final
# decision about whether two commits are the same, across different repos.
# $1 - commit ref
# $2 - paths filter
commit_signature()
{
	local ref=$1
	shift
	git show --pretty='("%s")|%aI|%b' --shortstat $ref -- "${@-.}" | tr '\n' '|'
}

# Cherry-pick commits touching libarena-related files
# $1 - baseline_tag
# $2 - tip_tag
cherry_pick_commits()
{
	local manual_mode=${MANUAL_MODE:-0}
	local baseline_tag=$1
	local tip_tag=$2
	local new_commits
	local signature
	local should_skip
	local synced_cnt
	local manual_check
	local libarena_conflict_cnt
	local desc

	new_commits=$(git rev-list --no-merges --topo-order --reverse ${baseline_tag}..${tip_tag} -- "${LIBARENA_PATHS[@]}")
	for new_commit in ${new_commits}; do
		desc="$(commit_desc ${new_commit})"
		signature="$(commit_signature ${new_commit} "${LIBARENA_PATHS[@]}")"
		synced_cnt=$(grep -F "${signature}" ${TMP_DIR}/libarena_commits.txt | wc -l)
		manual_check=0
		if ((${synced_cnt} > 0)); then
			# commit with the same subject is already in libarena, but it's
			# not 100% the same commit, so check with user
			echo "Commit '${desc}' is synced into libarena as:"
			grep -F "${signature}" ${TMP_DIR}/libarena_commits.txt | \
				cut -d'|' -f1 | sed -e 's/^/- /'
			if ((${manual_mode} != 1 && ${synced_cnt} == 1)); then
				echo "Skipping '${desc}' due to unique match..."
				continue
			fi
			if ((${synced_cnt} > 1)); then
				echo "'${desc} matches multiple commits, please, double-check!"
				manual_check=1
			fi
		fi
		if ((${manual_mode} == 1 || ${manual_check} == 1)); then
			read -p "Do you want to skip '${desc}'? [y/N]: " should_skip
			case "${should_skip}" in
				"y" | "Y")
					echo "Skipping '${desc}'..."
					continue
					;;
			esac
		fi
		# commit hasn't been synced into libarena yet
		echo "Picking '${desc}'..."
		if ! git cherry-pick ${new_commit} &>/dev/null; then
			echo "Warning! Cherry-picking '${desc} failed, checking if it's non-libarena files causing problems..."
			libarena_conflict_cnt=$(git diff --name-only --diff-filter=U -- "${LIBARENA_PATHS[@]}" | wc -l)
			conflict_cnt=$(git diff --name-only | wc -l)
			prompt_resolution=1

			if ((${libarena_conflict_cnt} == 0)); then
				echo "Looks like only non-libarena files have conflicts, ignoring..."
				if ((${conflict_cnt} == 0)); then
					echo "Empty cherry-pick, skipping it..."
					git cherry-pick --abort
					continue
				fi

				git add .
				# GIT_EDITOR=true to avoid editor popping up to edit commit message
				if ! GIT_EDITOR=true git cherry-pick --continue &>/dev/null; then
					echo "Error! That still failed! Please resolve manually."
				else
					echo "Success! All cherry-pick conflicts were resolved for '${desc}'!"
					prompt_resolution=0
				fi
			fi

			if ((${prompt_resolution} == 1)); then
				read -p "Error! Cherry-picking '${desc}' failed, please fix manually and press <return> to after successfully running cherry-pick --continue..."
			fi
		fi
		# Append signature of just cherry-picked commit to avoid
		# potentially cherry-picking the same commit twice later when
		# processing bpf tree commits. At this point we don't know yet
		# the final commit sha in libarena repo, so we record Linux SHA
		# instead as LINUX_<sha>.
		echo LINUX_$(git log --pretty='%h' -n1) "${signature}" >> ${TMP_DIR}/libarena_commits.txt
	done
}

cd_workdir ${LIBARENA_REPO}
STANDALONE_ABS_DIR=$(pwd)
echo "Dumping existing libarena commit signatures..."
for h in $(git log --pretty='%h' -n500); do
	echo $h "$(commit_signature $h)" >> ${TMP_DIR}/libarena_commits.txt
done

# Use current kernel repo HEAD as a source of patches
cd_workdir ${LINUX_REPO}
LINUX_ABS_DIR=$(pwd)
TIP_SYM_REF=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
TIP_COMMIT=$(git rev-parse HEAD)
BPF_TIP_COMMIT=$(git rev-parse ${BPF_BRANCH})
BASELINE_TAG=libarena-baseline-${SUFFIX}
TIP_TAG=libarena-tip-${SUFFIX}
BPF_BASELINE_TAG=libarena-bpf-baseline-${SUFFIX}
BPF_TIP_TAG=libarena-bpf-tip-${SUFFIX}
VIEW_TAG=libarena-view-${SUFFIX}
LIBARENA_SYNC_TAG=libarena-sync-${SUFFIX}

# Squash state of kernel repo at baseline into single commit
SQUASH_BASE_TAG=libarena-squash-base-${SUFFIX}
SQUASH_TIP_TAG=libarena-squash-tip-${SUFFIX}
SQUASH_COMMIT=$(git commit-tree ${BASELINE_COMMIT}^{tree} -m "BASELINE SQUASH ${BASELINE_COMMIT}")

echo "WORKDIR:          ${WORKDIR}"
echo "LINUX REPO:       ${LINUX_REPO}"
echo "LIBARENA REPO:    ${LIBARENA_REPO}"
echo "TEMP DIR:         ${TMP_DIR}"
echo "SUFFIX:           ${SUFFIX}"
echo "BASE COMMIT:      '$(commit_desc ${BASELINE_COMMIT})'"
echo "TIP COMMIT:       '$(commit_desc ${TIP_COMMIT})'"
echo "BPF BASE COMMIT:  '$(commit_desc ${BPF_BASELINE_COMMIT})'"
echo "BPF TIP COMMIT:   '$(commit_desc ${BPF_TIP_COMMIT})'"
echo "SQUASH COMMIT:    ${SQUASH_COMMIT}"
echo "BASELINE TAG:     ${BASELINE_TAG}"
echo "TIP TAG:          ${TIP_TAG}"
echo "BPF BASELINE TAG: ${BPF_BASELINE_TAG}"
echo "BPF TIP TAG:      ${BPF_TIP_TAG}"
echo "SQUASH BASE TAG:  ${SQUASH_BASE_TAG}"
echo "SQUASH TIP TAG:   ${SQUASH_TIP_TAG}"
echo "VIEW TAG:         ${VIEW_TAG}"
echo "LIBARENA SYNC TAG:  ${LIBARENA_SYNC_TAG}"

echo "PATCHES:          ${TMP_DIR}/patches"

git branch ${BASELINE_TAG} ${BASELINE_COMMIT}
git branch ${TIP_TAG} ${TIP_COMMIT}
git branch ${BPF_BASELINE_TAG} ${BPF_BASELINE_COMMIT}
git branch ${BPF_TIP_TAG} ${BPF_TIP_COMMIT}
git branch ${SQUASH_BASE_TAG} ${SQUASH_COMMIT}
git checkout -b ${SQUASH_TIP_TAG} ${SQUASH_COMMIT}

# Cherry-pick new commits onto squashed baseline commit
cherry_pick_commits ${BASELINE_TAG} ${TIP_TAG}
cherry_pick_commits ${BPF_BASELINE_TAG} ${BPF_TIP_TAG}

# Move all libarena files into __libarena directory.
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --prune-empty -f --tree-filter "${LIBARENA_TREE_FILTER}" ${SQUASH_TIP_TAG} ${SQUASH_BASE_TAG}
# Make __libarena a new root directory
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --prune-empty -f --subdirectory-filter __libarena ${SQUASH_TIP_TAG} ${SQUASH_BASE_TAG}

cleanup()
{
	echo "Cleaning up..."
	rm -r ${TMP_DIR}
	cd_workdir ${LINUX_REPO}
	git checkout ${TIP_SYM_REF}
	git branch -D ${BASELINE_TAG} ${TIP_TAG} ${BPF_BASELINE_TAG} ${BPF_TIP_TAG} \
		      ${SQUASH_BASE_TAG} ${SQUASH_TIP_TAG} ${VIEW_TAG} || true

	cd_workdir .
	echo "DONE."
}

# If there are no new commits with  libarena-related changes, bail out
COMMIT_CNT=$(git rev-list --count ${SQUASH_BASE_TAG}..${SQUASH_TIP_TAG})
if ((${COMMIT_CNT} <= 0)); then
    echo "No new changes to apply, we are done!"
    cleanup
    exit 2
fi

# Exclude baseline commit and generate nice cover letter with summary
git format-patch --no-signature ${SQUASH_BASE_TAG}..${SQUASH_TIP_TAG} --cover-letter -o ${TMP_DIR}/patches

# Now is time to re-apply libarena-related linux patches to libarena repo
cd_workdir ${LIBARENA_REPO}
git checkout -b ${LIBARENA_SYNC_TAG}

for patch in $(ls -1 ${TMP_DIR}/patches | tail -n +2); do
	if ! git am -3 --committer-date-is-author-date "${TMP_DIR}/patches/${patch}"; then
		if ! patch -p1 --merge < "${TMP_DIR}/patches/${patch}"; then
			read -p "Applying ${TMP_DIR}/patches/${patch} failed, please resolve manually and press <return> to proceed..."
		fi
		git am --continue
	fi
done

echo "Regenerating .mailmap..."
cd_workdir "${LINUX_REPO}"
git checkout "${TIP_SYM_REF}"
cd_workdir "${LIBARENA_REPO}"
"${LIBARENA_REPO}"/scripts/mailmap-update.sh "${LIBARENA_REPO}" "${LINUX_REPO}"
# if anything changed, commit it
mailmap_changes=$(git status --porcelain .mailmap | wc -l)
if ((${mailmap_changes} == 1)); then
	git add .mailmap
	git commit -s -m "sync: update .mailmap

Update .mailmap based on libarena's list of contributors and on the latest
.mailmap version in the upstream repository.
" -- .mailmap
fi

# Use generated cover-letter as a template for "sync commit" with
# baseline and checkpoint commits from kernel repo (and leave summary
# from cover letter intact, of course)
echo ${TIP_COMMIT} > CHECKPOINT-COMMIT &&					      \
echo ${BPF_TIP_COMMIT} > BPF-CHECKPOINT-COMMIT &&				      \
git add CHECKPOINT-COMMIT &&							      \
git add BPF-CHECKPOINT-COMMIT &&						      \
awk '/\*\*\* BLURB HERE \*\*\*/ {p=1} p' ${TMP_DIR}/patches/0000-cover-letter.patch | \
sed "s/\*\*\* BLURB HERE \*\*\*/\
sync: latest libarena changes from kernel\n\
\n\
Syncing latest libarena commits from kernel repository.\n\
Baseline bpf-next commit:   ${BASELINE_COMMIT}\n\
Checkpoint bpf-next commit: ${TIP_COMMIT}\n\
Baseline bpf commit:        ${BPF_BASELINE_COMMIT}\n\
Checkpoint bpf commit:      ${BPF_TIP_COMMIT}/" |				      \
git commit -s --file=-

echo "SUCCESS! ${COMMIT_CNT} commits synced."

echo "Verifying Linux's and Github's libarena state"

cd_workdir ${LINUX_REPO}
git checkout -b ${VIEW_TAG} ${TIP_COMMIT}
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --tree-filter "${LIBARENA_TREE_FILTER}" ${VIEW_TAG}^..${VIEW_TAG}
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --subdirectory-filter __libarena ${VIEW_TAG}^..${VIEW_TAG}
git ls-files > ${TMP_DIR}/linux-view.ls

cd_workdir ${LIBARENA_REPO}
echo "Comparing file contents..."
CONSISTENT=1
for F in $(cat ${TMP_DIR}/linux-view.ls); do
	if ! diff -u "${LINUX_ABS_DIR}/${F}" "${STANDALONE_ABS_DIR}/${F}"; then
		echo "${LINUX_ABS_DIR}/${F} and ${STANDALONE_ABS_DIR}/${F} are different!"
		CONSISTENT=0
	fi
done
if ((${CONSISTENT} == 1)); then
	echo "Great! Content is identical!"
else
	ignore_inconsistency=n
	echo "Unfortunately, there are some inconsistencies, please double check."
	read -p "Does everything look good? [y/N]: " ignore_inconsistency
	case "${ignore_inconsistency}" in
		"y" | "Y")
			echo "Ok, proceeding..."
			;;
		*)
			echo "Oops, exiting with error..."
			exit 4
	esac
fi

cleanup
