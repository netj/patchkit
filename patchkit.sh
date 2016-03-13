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

error() { echo >&2 "$@"; }
usage() {
    local scpt=$1; shift
    sed -n '2,${ s/^# //p; /^##$/q; }' <"$scpt"
    [[ $# -eq 0 ]] || error "$@"
}


patch=()
copy=()
file_id() { sha1sum <<<"$1" | cut -b1-40; }

# vocabularies for declaring what to patch/copy
# that simply capture the parameters in arrays and as shell functions
register() {
    local what=$1; shift
    local file=${1:?missing filename}; shift
    eval "$what"'+=("$file")'
    local file_id=$(file_id "$file")
    local verb=
    for verb in update import delete; do
        eval "$verb"'_'"$file_id"'() {
            '"$verb"'_'"$what"' '"$(printf " %q" "$file" "$@")"'
        }'
    done
}
patch() { register patch "$@"; }
copy()  { register copy "$@"; }

# override `exit` to present an interactive user interface
exit() {
    # actual implementation of how to get things done
    update_patch() {
        local file=$1; shift
        local "$@"
        echo "$begin"
        error "Not implemented update_patch $1"
    }
    import_patch() { error "Not implemented import_patch $1"
    }
    delete_patch() { error "Not implemented delete_patch $1"
    }
    update_copy() { error "Not implemented update_copy $1"
    }
    import_copy() { error "Not implemented import_copy $1"
    }
    delete_copy() { error "Not implemented delete_copy $1"
    }

    # route verbs on file names to the actual compiled units
    Update() { update_"$(file_id "$1")"; }
    Import() { import_"$(file_id "$1")"; }
    Delete() { delete_"$(file_id "$1")"; }
    iterate() {
        local verb=$1; shift
        for obj; do "$verb" "$obj"; done
    }

    # enumerate possible options
    objects=()
    [[ ${#patch[@]} -eq 0 ]] || objects+=("${patch[@]}")
    [[  ${#copy[@]} -eq 0 ]] || objects+=("${copy[@]}")
    set -- {Update,Import,Delete}" everything"
    local o=
    for o in "${objects[@]}"; do
        set -- "$@" {Update,Import,Delete}" only $o"
    done
    local task=
    select task in "$@"; do
        case $task in
            *" only "*)
                local verb=${task%% only *}
                local object=${task#$verb only }
                "$verb" "$object"
                ;;

            *" everything")
                iterate "${task% everything}" "${objects[@]}"
                ;;

            *) # other responses
                case $REPLY in
                    q) break ;;
                    *) error "$REPLY: unrecognized option" || true
                esac
        esac
    done
    command exit
}
