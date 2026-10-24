#!/usr/bin/env bash
#
# drun — interactively pick a local Docker image and run a container from it.
#
# Usage:
#   drun                          # fully interactive
#   drun ubuntu:24.04             # skip the picker, still ask the rest
#   drun -p 8080:80 --rm          # extra args are forwarded to `docker run`
#
# Features:
#   - Image picker: fzf if installed (brew install fzf), numbered menu otherwise
#   - If a container with the chosen name exists: enter it, replace it, or rename
#   - Optional bind-mount of $PWD at /workspace
#   - bash / sh / image-default command, auto-fallback to sh for bash-less images
#   - Keeps the container by default (re-enter it later), or --rm on request
#   - Compatible with macOS's stock bash 3.2

# ---------- sanity checks -------------------------------------------------------
command -v docker >/dev/null 2>&1 || { echo "drun: docker not found" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "drun: Docker daemon unreachable — start Docker Desktop" >&2; exit 1; }

tty_flags=(-i -t)
[ -t 0 ] || tty_flags=(-i)          # still works when input is piped

# ---------- image selection -------------------------------------------------------
selected=""

# `drun <image> ...` — if the first arg is a real image, skip the picker
if [ "$#" -gt 0 ] && docker image inspect "$1" >/dev/null 2>&1; then
    selected="$1"; shift
else
    # tagged images only; dangling <none> images are hidden
    img_data=$(docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' | grep -v '^<none>')
    [ -n "$img_data" ] || { echo "drun: no tagged images — build or pull one first" >&2; exit 1; }

    tags=(); sizes=(); ages=()
    while IFS=$'\t' read -r t s a; do
        tags+=("$t"); sizes+=("$s"); ages+=("$a")
    done <<EOF
 $img_data
EOF
    n=${#tags[@]}

    if command -v fzf >/dev/null 2>&1; then
        disp=(); i=0
        while [ "$i" -lt "$n" ]; do
            disp+=("$(printf '%-48s %10s  %s' "${tags[$i]}" "${sizes[$i]}" "${ages[$i]}")")
            i=$((i + 1))
        done
        line=$(printf '%s\n' "${disp[@]}" | fzf --prompt='image> ' --reverse)
        [ -n "$line" ] || exit 0
        selected="${line%% *}"                       # first column = repo:tag
    else
        printf '\n %-3s %-48s %10s  %s\n' '#' 'IMAGE' 'SIZE' 'CREATED'
        printf ' %s\n' '------------------------------------------------------------------------------'
        i=0
        while [ "$i" -lt "$n" ]; do
            printf ' %-3s %-48s %10s  %s\n' $((i + 1)) "${tags[$i]}" "${sizes[$i]}" "${ages[$i]}"
            i=$((i + 1))
        done
        while [ -z "$selected" ]; do
            printf '\nSelect image [1-%d] (q=quit): ' "$n"
            read -r ans || exit 0
            [ "$ans" = "q" ] && exit 0
            if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then
                selected="${tags[$((ans - 1))]}"
            fi
        done
    fi
fi
echo "→ image: $selected"

# ---------- container name --------------------------------------------------------
repo=${selected##*/}                                # strip registry/namespace
base=${repo%%:*}                                    # strip :tag
default_name=$(printf '%s' "$base" | tr -c '[:alnum:]._-' '-')
default_name=${default_name#-}; default_name=${default_name%-}
[ -n "$default_name" ] || default_name=dev

enter_existing() {                                  # $1 = container name
    docker start "$1" >/dev/null 2>&1 || { echo "drun: cannot start '$1'" >&2; return 1; }
    local sh=sh
    docker exec "$1" bash -c ':' >/dev/null 2>&1 && sh=bash
    exec docker exec "${tty_flags[@]}" "$1" "$sh"
}

cname=""
while [ -z "$cname" ]; do
    read -r -p "Container name [$default_name]: " name_in || exit 0
    cname=${name_in:-$default_name}
    if docker container inspect "$cname" >/dev/null 2>&1; then
        read -r -p "  '$cname' already exists — (e)nter, (r)eplace, (n)ew name, (q)uit [e]: " act || exit 0
        case "${act:-e}" in
            e) enter_existing "$cname" ;;           # exec replaces this script
            r) docker rm -f "$cname" >/dev/null && break ;;
            n) cname="" ;;
            q) exit 0 ;;
        esac
    else
        break
    fi
done

# ---------- run options -------------------------------------------------------------
echo
read -r -p "Bind-mount current directory to /workspace? [Y/n]: " m || exit 0
case "${m:-y}" in [nN]*) mount_cwd="" ;; *) mount_cwd="y" ;; esac

read -r -p "Command — (b)ash, (s)h, (d)efault image command [b]: " c || exit 0
case "${c:-b}" in
    s) cmd="sh" ;;
    d) cmd="" ;;
    *) cmd="bash" ;;
esac

read -r -p "Remove container on exit? [y/N]: " r || exit 0
case "${r:-n}" in [yY]*) rm_flag="--rm" ;; *) rm_flag="" ;; esac

read -r -p "Extra docker-run args (e.g. -p 8080:80), blank = none: " extra || exit 0

# ---------- run ------------------------------------------------------------------------
run_args=(run "${tty_flags[@]}" --name "$cname")
[ -n "$rm_flag" ] && run_args+=("$rm_flag")
[ "$mount_cwd" = "y" ] && run_args+=(-v "$PWD:/workspace")
# shellcheck disable=SC2206   # word-splitting of $extra is intended
[ -n "$extra" ] && run_args+=($extra)
[ "$#" -gt 0 ] && run_args+=("$@")
run_args+=("$selected")
[ -n "$cmd" ] && run_args+=("$cmd")

echo "→ docker ${run_args[*]}"
echo
rc=0

docker ${run_args[@]} || rc=$?

# bash-less images (alpine, busybox, ...): 126/127 = executable not found
if { [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; } && [ "$cmd" = "bash" ]; then
    echo "drun: image has no bash — retrying with sh" >&2
    run_args[${#run_args[@]}-1]=sh                  # replace last arg: bash -> sh
    rc=0
    docker "${run_args[@]}" || rc=$?
fi

if [ -z "$rm_flag" ]; then
    echo
    echo "drun: container '$cname' was kept. To come back later:"
    echo "    docker start $cname && docker exec -it $cname bash"
    echo "  (or just run drun again and reuse the same name)"
fi
exit "$rc"
