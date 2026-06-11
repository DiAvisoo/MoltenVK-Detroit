#!/bin/bash

set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: compile_msl_library_cache.sh [options] [cache-dir]
       VK_DTR_MSL_LIBRARY_DISK_CACHE_DIR=<cache-dir> compile_msl_library_cache.sh [options]

Compiles MoltenVK persistent MSL disk-cache source dumps from msl-v1-*.metal
to matching .metallib files that VK_DTR_MSL_LIBRARY_DISK_CACHE_DIR can load.
If no directory is provided, the default is ~/Library/Caches/MoltenVK/detroit-msl-library-cache-full.

Options:
  -f, --force                         Rebuild existing .metallib files.
  -j, --jobs <count>                  Compile up to <count> sources concurrently. Default: 1.
      --slow-log <path>               Only compile hashes found in slow Metal compile log lines.
      --min-compile-ms <ms>           With --slow-log, include entries at least this slow. Default: 0.
      --filter-out <path>             Write selected hashes for MVK_DTR_MSL_LIBRARY_DISK_CACHE_FILTER_PATH.
      --merge-filter-out <path>       Merge selected hashes into an existing filter file.
      --prune-unselected-metallibs    Delete .metallib files not selected by --slow-log.
      --prune-unselected-sources      Delete .metal/.meta files not selected by --slow-log.
      --prune-unselected              Delete unselected .metallib/.metal/.meta files.
  -h, --help                          Show this help.
USAGE
}

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

force=0
jobs="${JOBS:-1}"
cache_dir_arg=""
slow_log_arg=""
min_compile_ms="0"
filter_out_arg=""
merge_filter_out=0
prune_unselected_metallibs=0
prune_unselected_sources=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		-f|--force)
			force=1
			shift
			;;
		-j|--jobs)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			jobs="$2"
			shift 2
			;;
		--jobs=*)
			jobs="${1#--jobs=}"
			shift
			;;
		--slow-log)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			slow_log_arg="$2"
			shift 2
			;;
		--slow-log=*)
			slow_log_arg="${1#--slow-log=}"
			shift
			;;
		--min-compile-ms)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			min_compile_ms="$2"
			shift 2
			;;
		--min-compile-ms=*)
			min_compile_ms="${1#--min-compile-ms=}"
			shift
			;;
		--filter-out)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			filter_out_arg="$2"
			shift 2
			;;
		--filter-out=*)
			filter_out_arg="${1#--filter-out=}"
			shift
			;;
		--merge-filter-out)
			[ "$#" -ge 2 ] || die "$1 requires a value"
			filter_out_arg="$2"
			merge_filter_out=1
			shift 2
			;;
		--merge-filter-out=*)
			filter_out_arg="${1#--merge-filter-out=}"
			merge_filter_out=1
			shift
			;;
		--prune-unselected-metallibs)
			prune_unselected_metallibs=1
			shift
			;;
		--prune-unselected-sources)
			prune_unselected_sources=1
			shift
			;;
		--prune-unselected)
			prune_unselected_metallibs=1
			prune_unselected_sources=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			die "unknown option: $1"
			;;
		*)
			[ -z "$cache_dir_arg" ] || die "only one cache directory can be specified"
			cache_dir_arg="$1"
			shift
			;;
	esac
done

if [ "$#" -gt 0 ]; then
	[ -z "$cache_dir_arg" ] || die "only one cache directory can be specified"
	cache_dir_arg="$1"
	shift
fi

[ "$#" -eq 0 ] || die "unexpected extra arguments"

cache_dir="${cache_dir_arg:-${VK_DTR_MSL_LIBRARY_DISK_CACHE_DIR:-${MVK_DTR_MSL_LIBRARY_DISK_CACHE_DIR:-$HOME/Library/Caches/MoltenVK/detroit-msl-library-cache-full}}}"
[ -d "$cache_dir" ] || die "cache directory does not exist: $cache_dir"

case "$jobs" in
	''|*[!0-9]*) die "jobs must be a positive integer" ;;
esac
[ "$jobs" -gt 0 ] || die "jobs must be a positive integer"

perl -e 'exit($ARGV[0] =~ /^\d+(\.\d+)?$/ ? 0 : 1)' "$min_compile_ms" || die "min compile ms must be a non-negative number"

if [ -n "$slow_log_arg" ]; then
	[ -f "$slow_log_arg" ] || die "slow log does not exist: $slow_log_arg"
elif [ "$prune_unselected_metallibs" = "1" ] || [ "$prune_unselected_sources" = "1" ]; then
	die "prune options require --slow-log"
fi

if ! metal_tool="$(xcrun -sdk macosx -find metal 2>/dev/null)"; then
	die "Metal Toolchain unavailable; run: xcodebuild -downloadComponent MetalToolchain"
fi

source_list="$(mktemp "${TMPDIR:-/tmp}/mvk-msl-sources.XXXXXX")"
selected_hashes=""

cleanup() {
	rm -f "$source_list"
	[ -z "$selected_hashes" ] || rm -f "$selected_hashes"
}
trap cleanup EXIT

if [ -n "$slow_log_arg" ]; then
	selected_hashes="$(mktemp "${TMPDIR:-/tmp}/mvk-msl-hashes.XXXXXX")"
	perl -ne '
		BEGIN { $min_ms = $ARGV[0]; shift @ARGV; }
		if (/slow Metal library compile .*msl_hash=([0-9a-fA-F]+).*elapsed=([0-9.]+)ms/) {
			$hashes{lc($1)} = 1 if $2 >= $min_ms;
		}
		END { print "$_\n" for sort keys %hashes; }
	' "$min_compile_ms" "$slow_log_arg" > "$selected_hashes"

	[ -s "$selected_hashes" ] || die "no slow compile hashes matched: $slow_log_arg"
	find "$cache_dir" -type f -name 'msl-v1-*.metal' -print0 |
		SELECTED_HASHES_PATH="$selected_hashes" perl -0ne '
			BEGIN {
				open(my $fh, "<", $ENV{"SELECTED_HASHES_PATH"}) or die "open selected hashes failed: $!\n";
				local $/ = "\n";
				while (my $line = <$fh>) { chomp($line); $hashes{lc($line)} = 1 if $line =~ /[0-9a-fA-F]/; }
			}
			print if /-h([0-9a-fA-F]+)-s/ && $hashes{lc($1)};
		' > "$source_list"
else
	find "$cache_dir" -type f -name 'msl-v1-*.metal' -print0 > "$source_list"
fi

source_count="$(perl -0ne '$count++; END { print $count + 0 }' "$source_list")"
if [ "$source_count" -eq 0 ]; then
	if [ -n "$slow_log_arg" ]; then
		printf 'No matching msl-v1-*.metal files found in %s\n' "$cache_dir"
	else
		printf 'No msl-v1-*.metal files found in %s\n' "$cache_dir"
	fi
	exit 0
fi

if [ -n "$slow_log_arg" ]; then
	hash_count="$(perl -ne '$count++; END { print $count + 0 }' "$selected_hashes")"
	printf 'Selected %s source(s) from %s slow hash(es).\n' "$source_count" "$hash_count"
fi

if [ -n "$filter_out_arg" ]; then
	filter_dir="${filter_out_arg%/*}"
	if [ "$filter_dir" != "$filter_out_arg" ]; then
		mkdir -p "$filter_dir"
	fi
	filter_tmp="${filter_out_arg}.tmp.$$"
	rm -f "$filter_tmp"
	if [ -n "$selected_hashes" ]; then
		if [ "$merge_filter_out" = "1" ] && [ -f "$filter_out_arg" ]; then
			cat "$filter_out_arg" "$selected_hashes" | perl -ne '
				chomp;
				$hashes{lc($_)} = 1 if /[0-9a-fA-F]/;
				END { print "$_\n" for sort keys %hashes; }
			' > "$filter_tmp"
		else
			cp "$selected_hashes" "$filter_tmp"
		fi
	else
		perl -0ne '
			$hashes{lc($1)} = 1 if /-h([0-9a-fA-F]+)-s/;
			END { print "$_\n" for sort keys %hashes; }
		' "$source_list" > "$filter_tmp"
	fi
	mv "$filter_tmp" "$filter_out_arg"
	printf 'Wrote filter %s\n' "$filter_out_arg"
fi

prune_unselected() {
	local label="$1"
	shift
	local removed
	removed="$(
		find "$@" -print0 |
			SELECTED_HASHES_PATH="$selected_hashes" perl -0ne '
				BEGIN {
					open(my $fh, "<", $ENV{"SELECTED_HASHES_PATH"}) or die "open selected hashes failed: $!\n";
					local $/ = "\n";
					while (my $line = <$fh>) { chomp($line); $hashes{lc($line)} = 1 if $line =~ /[0-9a-fA-F]/; }
				}
				if (/-h([0-9a-fA-F]+)-s/ && !$hashes{lc($1)}) {
					unlink $_ or warn "remove $_ failed: $!\n";
					$count++;
				}
				END { print $count + 0; }
			'
	)"
	printf 'Removed %s unselected %s file(s).\n' "$removed" "$label"
}

if [ "$prune_unselected_metallibs" = "1" ]; then
	prune_unselected ".metallib" "$cache_dir" -type f -name 'msl-v1-*.metallib'
fi

if [ "$prune_unselected_sources" = "1" ]; then
	prune_unselected ".metal/.meta" "$cache_dir" -type f \( -name 'msl-v1-*.metal' -o -name 'msl-v1-*.meta' \)
fi

progress_total="$source_count"
progress_done=0
progress_built=0
progress_skipped=0
progress_width=30
progress_start_epoch="$(date +%s)"
progress_step=$(( (progress_total + 199) / 200 ))
[ "$progress_step" -gt 0 ] || progress_step=1
progress_tty=0
[ -t 2 ] && progress_tty=1

format_duration() {
	local seconds="$1"
	local hours=$((seconds / 3600))
	local minutes=$(((seconds % 3600) / 60))
	local secs=$((seconds % 60))

	printf '%02d:%02d:%02d' "$hours" "$minutes" "$secs"
}

progress_bar() {
	local filled="$1"
	local width="$2"
	local bar=""
	local i

	for ((i = 0; i < filled; i++)); do bar="${bar}#"; done
	for ((i = filled; i < width; i++)); do bar="${bar}-"; done
	printf '%s' "$bar"
}

progress_render() {
	local percent=0
	local filled=0
	local bar
	local now_epoch
	local elapsed_seconds
	local elapsed
	local eta="--:--:--"

	if [ "$progress_total" -gt 0 ]; then
		percent=$(( progress_done * 100 / progress_total ))
		filled=$(( progress_done * progress_width / progress_total ))
	fi
	bar="$(progress_bar "$filled" "$progress_width")"
	now_epoch="$(date +%s)"
	elapsed_seconds=$((now_epoch - progress_start_epoch))
	elapsed="$(format_duration "$elapsed_seconds")"
	if [ "$progress_done" -gt 0 ]; then
		eta="$(format_duration $(( elapsed_seconds * (progress_total - progress_done) / progress_done )))"
	fi

	if [ "$progress_tty" = "1" ]; then
		printf '\r[%s] %3d%% %d/%d built=%d skipped=%d elapsed=%s eta=%s' "$bar" "$percent" "$progress_done" "$progress_total" "$progress_built" "$progress_skipped" "$elapsed" "$eta" >&2
	else
		printf '[%s] %3d%% %d/%d built=%d skipped=%d elapsed=%s eta=%s\n' "$bar" "$percent" "$progress_done" "$progress_total" "$progress_built" "$progress_skipped" "$elapsed" "$eta" >&2
	fi
}

progress_begin() {
	printf 'Compiling %d MSL source(s) with %d job(s)...\n' "$progress_total" "$jobs" >&2
	progress_render
	return 0
}

progress_record() {
	case "$1" in
		built) progress_built=$((progress_built + 1)) ;;
		skip) progress_skipped=$((progress_skipped + 1)) ;;
	esac
	progress_done=$((progress_done + 1))

	if [ "$progress_done" -eq "$progress_total" ] || [ $((progress_done % progress_step)) -eq 0 ]; then
		progress_render
	fi
	return 0
}

progress_finish() {
	local elapsed_seconds
	local elapsed

	if [ "$progress_done" -lt "$progress_total" ]; then
		progress_render
	fi
	if [ "$progress_tty" = "1" ]; then
		printf '\n' >&2
	fi
	elapsed_seconds=$(($(date +%s) - progress_start_epoch))
	elapsed="$(format_duration "$elapsed_seconds")"
	printf 'Done: %d built, %d skipped, %d total in %s.\n' "$progress_built" "$progress_skipped" "$progress_total" "$elapsed" >&2
}

compile_one() {
	local metal_path="$1"
	local metallib_path="${metal_path%.metal}.metallib"
	local meta_path="${metal_path%.metal}.meta"
	local tmp_path="${metallib_path}.tmp.$$"
	local log_path="${tmp_path}.log"
	local fp_flags="4294967295"
	local is_position_invariant="0"
	local key
	local value
	local fp_flags_num
	local relaxed_mask=$((0x00000004 | 0x00000008 | 0x00010000 | 0x00020000))
	local fast_mask=$((0x00000001 | 0x00000002 | relaxed_mask))
	local math_mode="safe"
	local fp32_functions="precise"
	local metal_args=()

	if [ "$force" != "1" ] && [ -f "$metallib_path" ] && [ "$metallib_path" -nt "$metal_path" ]; then
		printf 'skip\n'
		return 0
	fi

	if [ -f "$meta_path" ]; then
		while IFS='=' read -r key value; do
			case "$key" in
				fp_fast_math_flags) fp_flags="$value" ;;
				is_position_invariant) is_position_invariant="$value" ;;
			esac
		done < "$meta_path"
	fi

	fp_flags_num=$((10#$fp_flags))
	if [ $((fp_flags_num & fast_mask)) -eq "$fast_mask" ]; then
		math_mode="fast"
		fp32_functions="fast"
	elif [ $((fp_flags_num & relaxed_mask)) -eq "$relaxed_mask" ]; then
		math_mode="relaxed"
	fi
	metal_args=("-fmetal-math-mode=$math_mode" "-fmetal-math-fp32-functions=$fp32_functions")
	if [ "$is_position_invariant" != "0" ]; then
		metal_args+=("-fpreserve-invariance")
	fi

	rm -f "$tmp_path" "$log_path"
	trap 'rm -f "$tmp_path" "$log_path"' RETURN
	if ! "$metal_tool" "${metal_args[@]}" -o "$tmp_path" "$metal_path" 2> "$log_path"; then
		printf 'compile failed: %s\n' "$metal_path" >&2
		while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "$log_path"
		return 1
	fi
	mv "$tmp_path" "$metallib_path"
	trap - RETURN
	rm -f "$log_path"
	printf 'built\n'
}

progress_begin
if [ "$jobs" -eq 1 ]; then
	while IFS= read -r -d '' metal_path; do
		status="$(compile_one "$metal_path")"
		progress_record "$status"
	done < "$source_list"
	progress_finish
else
	export metal_tool force
	xargs -0 -n 1 -P "$jobs" bash -c '
		set -euo pipefail
		metal_path="$1"
		metallib_path="${metal_path%.metal}.metallib"
		meta_path="${metal_path%.metal}.meta"
		tmp_path="${metallib_path}.tmp.$$"
		log_path="${tmp_path}.log"
		fp_flags="4294967295"
		is_position_invariant="0"
		relaxed_mask=$((0x00000004 | 0x00000008 | 0x00010000 | 0x00020000))
		fast_mask=$((0x00000001 | 0x00000002 | relaxed_mask))
		math_mode="safe"
		fp32_functions="precise"
		metal_args=()

		if [ "$force" != "1" ] && [ -f "$metallib_path" ] && [ "$metallib_path" -nt "$metal_path" ]; then
			printf "skip\n"
			exit 0
		fi

		if [ -f "$meta_path" ]; then
			while IFS="=" read -r key value; do
				case "$key" in
					fp_fast_math_flags) fp_flags="$value" ;;
					is_position_invariant) is_position_invariant="$value" ;;
				esac
			done < "$meta_path"
		fi

		fp_flags_num=$((10#$fp_flags))
		if [ $((fp_flags_num & fast_mask)) -eq "$fast_mask" ]; then
			math_mode="fast"
			fp32_functions="fast"
		elif [ $((fp_flags_num & relaxed_mask)) -eq "$relaxed_mask" ]; then
			math_mode="relaxed"
		fi
		metal_args=("-fmetal-math-mode=$math_mode" "-fmetal-math-fp32-functions=$fp32_functions")
		if [ "$is_position_invariant" != "0" ]; then
			metal_args+=("-fpreserve-invariance")
		fi

		rm -f "$tmp_path" "$log_path"
		trap '\''rm -f "$tmp_path" "$log_path"'\'' EXIT
		if ! "$metal_tool" "${metal_args[@]}" -o "$tmp_path" "$metal_path" 2> "$log_path"; then
			printf "compile failed: %s\n" "$metal_path" >&2
			while IFS= read -r line; do printf "%s\n" "$line" >&2; done < "$log_path"
			exit 1
		fi
		mv "$tmp_path" "$metallib_path"
		trap - EXIT
		rm -f "$log_path"
		printf "built\n"
	' _ < "$source_list" | {
		while IFS= read -r status; do
			progress_record "$status"
		done
		progress_finish
	}
fi
