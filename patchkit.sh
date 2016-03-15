#!/usr/bin/env bash
# PatchKit -- a handy tool for maintaining patches and copies of files as a shell script
#
# $ . patchkit.sh "$@"
# Prints the necessary scripts for loading PatchKit vocabularies into a shell
# script.
#
# See github.com/netj/patchkit#readme for detailed usage.
##
# Author: Jaeho Shin <netj@cs.stanford.edu>
# Created: 2016-03-13
set -euo pipefail

Script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

msg()   { echo >&2 "# $*"; }
error() { echo >&2 "ERROR: $*"; false; }
usage() {
    local scpt=$1; shift
    sed -n '2,${ s/^# //p; /^##$/q; }' <"$scpt"
    [[ $# -eq 0 ]] || error "$@"
}


# extract tarball embedded in the patchkit script to a temporary space
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/patchkit-$(basename "$0").XXXXXXX")
trap cleanup EXIT
is_dirty=false
cleanup() {
    if $is_dirty; then
        # update tarball embedded in the patchkit script
        tar zvcf >(sed -e '1,/^exit ###*$/!d' \
                       -e '/^exit ###*$/r /dev/stdin' \
                       -i'~' "$Script") -C "$tmpdir" .
        msg "Updated $Script"
    fi
    rm -rf "$tmpdir"
}
[[ $(sed '1,/^exit ###*$/d' "$Script" | wc -l) -eq 0 ]] ||
tar zxf <(sed '1,/^exit ###*$/d' "$Script") -C "$tmpdir"

patch=()
copy=()
file_id() { sha1sum <<<"$1" | cut -b1-40; }

# vocabularies for declaring what to patch/copy
# that simply capture the parameters in arrays and as shell functions
looking_inside_patchkit=false
register() {
    local what=$1; shift
    local file=${1:?missing filename}; shift
    # register only existing files on either side
    [[ -e "$file" ]] || {
        if $looking_inside_patchkit; then
            error "$what: ignoring non-existent file: $file" || true
        else
            # check if the file is in the patchkit
            local looking_inside_patchkit=true
            pushd "$tmpdir" >/dev/null
            eval 'register "$what" '"$file"' "$@"'
            popd >/dev/null
        fi
        return
    }
    eval "$what"'+=("$file")'
    local file_id=$(file_id "$file")
    local verb=
    for verb in compare patch import edit forget; do
        eval "$verb"'_'"$file_id"'() {
            '"$verb"'_'"$what"' '"$(printf " %q" "$file" "$@")"'
        }'
    done
}
patch() {
    register patch "$@"
    # sanity check for missing arguments
    [[ $# -eq 0 ]] || local "$@"
    : ${begin:?line delineating the beginning of the block}
    : ${end:?line delineating the end of the block}
}
copy() {
    local f=
    for f; do
        [[ -e "$f" ]] || $looking_inside_patchkit || {
            # check if the file is in the patchkit
            # FIXME check both inside and outside
            local looking_inside_patchkit=true
            pushd "$tmpdir" >/dev/null
            eval 'copy '"$f"
            popd >/dev/null
            return
        }
        register copy "$f"
    done
}

# override `exit` to present an interactive user interface
exit() {
## actual implementation of how to get things done
# common actions
edit() {
    local file=$1; shift; [[ $# -eq 0 ]] || local "$@"
    vimdiff "$tmpdir"/"$file" "$file" || true
    is_dirty=true
}
forget() {
    local file=$1; shift; [[ $# -eq 0 ]] || local "$@"
    rm -f "$tmpdir"/"$file"
    msg "Forgot $file"
    is_dirty=true
}

# patch actions
snippet_last_imported() {
    cat "$tmpdir"/"$file" 2>/dev/null || {
        echo "$begin"
        echo "$end"
    }
}
snippet_on_file() {
    sed -e "/^$begin$/,/^$end$/!d" "$file" 2>/dev/null
}
compare_patch() {
    local file=$1; shift; [[ $# -eq 0 ]] || local "$@"
    diff -u <(snippet_last_imported) <(snippet_on_file) 2>/dev/null || true
}
patch_patch() {
    local file=$1; shift; [[ $# -eq 0 ]] || local "$@"
    if [[ $(snippet_on_file | wc -l) -gt 0 ]]; then
        # replace existing snippet
        snippet_last_imported |
        sed -e "/^$begin$/,/^$end$/{
            /^$end$/ r /dev/stdin
            d
        }" -i'~' "$file"
    else
        # or add new snippet
        touch "$file"
        snippet_last_imported |
        case ${add_to:-top} in
            top)
                mv -f "$file"{,'~'}
                cat - "$file"~ >"$file"
                ;;
            bottom)
                sed -e '$r /dev/stdin' -i'~' "$file"
                ;;
            *)
                error "add_to=$add_to unrecognized"
        esac
    fi
    msg "Patched $file"
}
import_patch() {
    local file=$1; shift; [[ $# -eq 0 ]] || local "$@"
    local s="$tmpdir"/"$file"
    mkdir -p $(dirname "$s")
    snippet_on_file >"$s"
    msg "Imported $file"
    is_dirty=true
}
edit_patch() { edit "$@"; }
forget_patch() { forget "$@"; }

# copy of file actions
compare_copy() {
    local file=$1; shift; [[ $# -eq 0 ]] || local "$@"
    diff -u "$tmpdir"/"$file" "$file" 2>/dev/null || true
}
patch_copy() {
    local file=$1; shift
    cp -f "$tmpdir"/"$file" "$file"
    msg "Patched $file"
}
import_copy() {
    local file=$1; shift
    mkdir -p "$(dirname "$tmpdir"/"$file")"
    cp -f "$file" "$tmpdir"/"$file"
    msg "Imported $file"
    is_dirty=true
}
edit_copy() { edit "$@"; }
forget_copy() { forget "$@"; }

# enumerate relevant files and allow them to be selected
objects=()
[[ ${#patch[@]} -eq 0 ]] || objects+=("${patch[@]}")
[[  ${#copy[@]} -eq 0 ]] || objects+=("${copy[@]}")
local selected=
selected=()
update_prompt() {
    PS3="################################################################################"
    if [[ ${#selected[@]} -gt 0 ]]; then
        PS3+=$'\n'"# (${#selected[@]} selected: ${selected[*]})"
        PS3+=$'\n'"##"
        PS3+=$'\n'"# Select/unselect more files (number, [a]ll, or [n]one)"
        PS3+=$'\n'"# Then [c]ompare, [p]atch, [i]mport, [e]dit, [f]orget"
    else
        PS3+=$'\n'"# Select files (number, [a]ll, or [n]one)"
    fi
    PS3+=", or [q]uit: "
}
update_prompt
echo "################################################################################"
local o=
select o in "${objects[@]}"; do
    local action=
    if [[ -n $o ]]; then
        # toggle selection
        if [[ ${#selected[@]} -gt 0 ]] && grep -qxFf <(printf '%s\n' "${selected[@]}") <<<"$o"; then
            # remove it
            # XXX wish this worked: selected-=("$o")
            local filtered= x=; filtered=()
            for x in "${selected[@]}"; do
                [[ $x != $o ]] || continue
                filtered+=("$x")
            done
            selected=()
            [[ ${#filtered[@]} -eq 0 ]] || selected=("${filtered[@]}")
        else
            # add it
            selected+=("$o")
        fi
    else
        case $REPLY in
            # select all/none
            a) selected=("${objects[@]}") ;;
            n) selected=() ;;
            # actions
            c) action=Compare   ;;
            p) action=Patch     ;;
            i) action=Import    ;;
            e) action=Edit      ;;
            f) action=Forget    ;;
            # quit
            q) break ;;
            *)
                error "$REPLY: Unrecognized response" || true
                continue
        esac
    fi
    if [[ -n $action ]]; then
        if [[ ${#selected[@]} -gt 0 ]]; then
            # map actions to the compiled shell functions
            for o in "${selected[@]}"; do
                "$(tr A-Z a-z <<<"$action")_$(file_id "$o")"
            done
        else
            error "No files selected" || true
            continue
        fi
    fi
    update_prompt
done

command exit
}
