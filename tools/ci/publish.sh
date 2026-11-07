#!/usr/bin/env bash
#
# Register freshly pushed images with the Treadmill switchboard and create a new
# revision of the image sets from `publish.json`.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

# The well-known `everyone` subject.
everyone="00000000-0000-0000-0000-000000000004"

# How long to keep retrying a registration the registry cannot serve yet.
register_timeout="${TREADMILL_REGISTER_TIMEOUT:-900}"

die() {
	echo "publish: $*" >&2
	exit 1
}

log() {
	echo "publish: $*" >&2
}

usage() {
	cat >&2 <<-USAGE
		usage: publish.sh --records <dir> [--config <publish.json>] [--dry-run]
	USAGE
	exit 2
}

records_dir=""
config="$repo/publish.json"
dry_run=false

while [ $# -gt 0 ]; do
	case "$1" in
	--records)
		records_dir="${2:?}"
		shift 2
		;;
	--config)
		config="${2:?}"
		shift 2
		;;
	--dry-run)
		dry_run=true
		shift
		;;
	-h | --help) usage ;;
	*) usage ;;
	esac
done

[ -n "$records_dir" ] || usage
[ -f "$config" ] || die "no such config: $config"
: "${TREADMILL_TOKEN:?TREADMILL_TOKEN must hold the switchboard API token}"

api_base="$(jq -er '.switchboard' "$config")/api/v1"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Pass the token through a header file, keeping it out of curl's argv.
(
	umask 077
	printf 'Authorization: Bearer %s\n' "$TREADMILL_TOKEN" >"$work/auth"
)

# api <method> <path> [<json-body>]: call the switchboard; the response body
# lands in $work/body, the HTTP status (000 on a transport error) on stdout.
api() {
	local method="$1" path="$2" body="${3:-}" status
	local args=(-sS -X "$method" -o "$work/body" -w '%{http_code}'
		-H "@$work/auth" -H 'Accept: application/json')
	if [ -n "$body" ]; then
		args+=(-H 'Content-Type: application/json' --data-binary "$body")
	fi
	: >"$work/body"
	status="$(curl "${args[@]}" "$api_base$path")" || status=000
	echo "$status"
}

# api_ok <expected-status> <method> <path> [<json-body>]: like `api`, failing
# unless the status matches.
api_ok() {
	local want="$1" status
	shift
	status="$(api "$@")"
	[ "$status" = "$want" ] ||
		die "$1 $2 returned $status (wanted $want): $(head -c 2000 "$work/body")"
}

# -- records ------------------------------------------------------------------

records="$(find "$records_dir" -type f -name '*.json' -print0 |
	xargs -0r jq -s '.')"
records="${records:-[]}"
jq -e 'all(.[]; (.image | type) == "string" and (.registry | type) == "string"
	and (.repository | type) == "string" and (.digest | test("^sha256:[0-9a-f]{64}$")))' \
	<<<"$records" >/dev/null || die "malformed records in $records_dir"
if [ "$(jq 'length' <<<"$records")" -eq 0 ]; then
	log "no images were pushed; nothing to publish"
	exit 0
fi

api_ok 200 GET /auth/whoami
me="$(jq -r '.user_id' "$work/body")"
log "publishing as $(jq -r '.name' "$work/body") ($me)$($dry_run && echo ', dry run')"

# -- register images ------------------------------------------------------------

# register <digest> <registry> <repository>: add the source, retrying while the
# switchboard cannot pull the manifest yet (502), or on transient faults.
register() {
	local digest="$1" registry="$2" repository="$3"
	local body status delay=15 deadline=$((SECONDS + register_timeout))
	body="$(jq -nc --arg registry "$registry" --arg repository "$repository" \
		'{$registry, $repository}')"
	while :; do
		status="$(api POST "/images/$digest/sources" "$body")"
		case "$status" in
		200 | 201) return 0 ;;
		000 | 429 | 502 | 503 | 504)
			[ "$SECONDS" -lt "$deadline" ] ||
				die "gave up registering $repository@$digest after ${register_timeout}s (last status $status)"
			log "$repository@$digest not registrable yet ($status), retrying in ${delay}s"
			sleep "$delay"
			delay=$((delay * 2 > 60 ? 60 : delay * 2))
			;;
		*) die "registering $repository@$digest returned $status: $(head -c 2000 "$work/body")" ;;
		esac
	done
}

while read -r record; do
	digest="$(jq -r '.digest' <<<"$record")"
	registry="$(jq -r '.registry' <<<"$record")"
	repository="$(jq -r '.repository' <<<"$record")"
	if $dry_run; then
		log "would register $registry/$repository@$digest"
		continue
	fi
	register "$digest" "$registry" "$repository"

	# Our source is the one we may manage. If another subject registered this
	# digest from the same repository first, the add was a no-op and that
	# owner's grants apply; the usability check below catches a gap.
	source_id="$(jq -r --arg registry "$registry" --arg repository "$repository" '
		first(.sources[] | select(.registry == $registry and .repository == $repository
			and (.permissions | index("manage")))) | .id // empty' "$work/body")"
	if [ -n "$source_id" ]; then
		api_ok 204 POST "/images/$digest/sources/$source_id/grants" \
			"$(jq -nc --arg s "$everyone" '{subject_id: $s, permission: "use"}')"
	else
		log "$repository@$digest is sourced by another owner; not granting"
	fi
	log "registered $registry/$repository@$digest"
done < <(jq -c '.[]' <<<"$records")

# -- roll image sets forward ---------------------------------------------------

api_ok 200 GET /image-sets
sets="$(cat "$work/body")"

while read -r name; do
	set_id="$(jq -r --arg n "$name" 'first(.[] | select(.canonical_name == $n)) | .id // empty' \
		<<<"$sets")"
	[ -n "$set_id" ] || die "no image set with canonical name $name visible to $me"
	latest="$(jq -r --arg id "$set_id" '.[] | select(.id == $id) | .latest_generation // empty' \
		<<<"$sets")"
	current='[]'
	if [ -n "$latest" ]; then
		api_ok 200 GET "/image-sets/$set_id/generations/$latest"
		current="$(jq -c '[.members[] | {manifest_digest, platform_profile, predicate}]' \
			"$work/body")"
	fi

	# A member built now takes the new digest; otherwise it keeps the digest of
	# the current member with the same profile and predicate.
	members="$(jq -c --arg name "$name" --argjson records "$records" \
		--argjson current "$current" '
		.sets[$name] | map(
			. as $m
			| (first($records[] | select(.image == $m.image)) | .digest)
				// (first($current[] | select(.platform_profile == $m.platform_profile
					and .predicate == $m.predicate)) | .manifest_digest)
				// error("\($m.image) was not built and is not in the current generation")
			| {manifest_digest: ., platform_profile: $m.platform_profile,
				predicate: $m.predicate})
		' "$config")" || die "cannot compute the members of $name"

	if [ "$members" = "$current" ]; then
		log "$name (generation ${latest:-none}) is unchanged"
		continue
	fi
	if $dry_run; then
		log "would append to $name (after generation ${latest:-none}): $members"
		continue
	fi
	api_ok 201 POST "/image-sets/$set_id/generations" "$(jq -nc --argjson m "$members" '{members: $m}')"
	generation="$(jq -r '.generation' "$work/body")"
	log "appended generation $generation to $name"
	jq -e 'all(.members[]; .usable_by_grantees)' "$work/body" >/dev/null ||
		die "$name generation $generation has members not every grantee can use: $(jq -c \
			'[.members[] | select(.usable_by_grantees | not) | .manifest_digest]' "$work/body")"
done < <(jq -r '.sets | keys[]' "$config")
