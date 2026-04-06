#!/usr/bin/env bash
set -euo pipefail

branch="main"
remote_url="git@github.com:whensun/klee_poke.git"

max_file_size=$((80 * 1024 * 1024))
max_file_count=20000

function ensure_gitignore_line() {
    local line="$1"
    touch .gitignore
    grep -qxF "$line" .gitignore || echo "$line" >> .gitignore
}

function check_tracked_file_count() {
    local count
    count="$(git ls-files | wc -l)"
    echo "Tracked file count: $count"
    if [ "$count" -gt "$max_file_count" ]; then
        echo "Error: tracked file count is above $max_file_count."
        exit 1
    fi
}

function check_tracked_file_sizes() {
    local found=0
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        local size
        size="$(wc -c < "$file")"
        if [ "$size" -gt "$max_file_size" ]; then
            echo "Error: file above 80MB: $file ($size bytes)"
            found=1
        fi
    done < <(git ls-files)

    if [ "$found" -ne 0 ]; then
        exit 1
    fi
}

function check_for_private_keys() {
    local found=0

    while IFS= read -r file; do
        [ -f "$file" ] || continue

        case "$file" in
            */id_rsa|*/id_dsa|*/id_ecdsa|*/id_ed25519|*.pem|*.key)
                echo "Error: suspicious key-like file tracked: $file"
                found=1
                continue
                ;;
        esac
    done < <(git ls-files)

    if [ "$found" -ne 0 ]; then
        echo "Remove those files from git tracking before pushing."
        exit 1
    fi
}

function setup_repo() {
    if [ ! -d ".git" ]; then
        git init
    fi

    if ! git remote get-url origin >/dev/null 2>&1; then
        git remote add origin "$remote_url"
    fi
}

function sync_branch() {
    git fetch origin || true

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git switch "$branch"
    else
        if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            git switch -c "$branch" --track "origin/$branch"
        else
            git switch -c "$branch"
        fi
    fi

    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        local_counts="$(git rev-list --left-right --count HEAD...origin/$branch)"
        ahead="$(echo "$local_counts" | awk '{print $1}')"
        behind="$(echo "$local_counts" | awk '{print $2}')"

        if git diff --quiet && git diff --cached --quiet; then
            if [ "$behind" -gt 0 ]; then
                git pull --rebase origin "$branch"
            fi
        else
            echo "Working tree is not clean, so skipping git pull --rebase."
            if [ "$behind" -gt 0 ]; then
                echo "Warning: local branch is behind origin/$branch by $behind commit(s)."
            fi
        fi
    fi
}

function setup_basic_ignores() {
    ensure_gitignore_line "qemu/tests/keys/id_rsa"
    ensure_gitignore_line "*.pem"
    ensure_gitignore_line "*.key"
    ensure_gitignore_line "id_rsa"
    ensure_gitignore_line "id_dsa"
    ensure_gitignore_line "id_ecdsa"
    ensure_gitignore_line "id_ed25519"
    ensure_gitignore_line "*.o"
    ensure_gitignore_line "*.elf"
    ensure_gitignore_line "*.bin"
    ensure_gitignore_line "*.pyc"
    ensure_gitignore_line "__pycache__/"
    ensure_gitignore_line "build/"
    ensure_gitignore_line "out/"
}

function untrack_known_secrets_if_present() {
    git rm --cached -f qemu/tests/keys/id_rsa 2>/dev/null || true
}

function main() {
    setup_repo
    sync_branch
    setup_basic_ignores
    untrack_known_secrets_if_present

    git add .

    check_tracked_file_count
    check_tracked_file_sizes
    check_for_private_keys

    if git diff --cached --quiet; then
        echo "No staged changes to commit."
    else
        git commit -m "What I did was committing some changes!"
    fi

    git push -u origin "$branch"
}

main "$@"