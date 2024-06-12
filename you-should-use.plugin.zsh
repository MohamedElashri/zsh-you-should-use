#!/bin/zsh

export YSU_VERSION='1.7.4'

if ! type "tput" > /dev/null; then
    printf "WARNING: tput command not found on your PATH.\nzsh-you-should-use will fallback to uncoloured messages\n"
    NONE=""
    BOLD=""
    RED=""
    YELLOW=""
    PURPLE=""
else
    NONE="$(tput sgr0)"
    BOLD="$(tput bold)"
    RED="$(tput setaf 1)"
    YELLOW="$(tput setaf 3)"
    PURPLE="$(tput setaf 5)"
fi

function check_alias_usage() {
    # Use an environment variable or a reasonable default if not defined
    local limit="${YSU_HISTORY_LIMIT:-10000}"
    local key

    declare -A usage
    for key in "${(@k)aliases}"; do
        usage[$key]=0
    done

    local current=0
    local total=$(wc -l < "$HISTFILE")
    total=$(( total > limit ? limit : total ))

    # Process substitution to avoid pipeline scope issues
    while read line; do
        local entry
        for entry in ${(@s/|/)line}; do
            # Trim leading whitespace using zsh parameter expansion
            entry="${entry##*( )}"
            local word=${entry[(w)1]}
            if [[ -n ${usage[$word]} ]]; then
                (( usage[$word]++ ))
            fi
        done
        (( current++ ))
        printf "[$current/$total]\r"
    done < <(tail -n $limit "$HISTFILE")

    printf "\r\033[K"

    # Output sorted usage
    for key in ${(k)usage}; do
        echo "${usage[$key]}: $key='${aliases[$key]}'"
    done | sort -rn -k1
}

function _write_ysu_buffer() {
    _YSU_BUFFER+="$@"
    # Automatically determine if the buffer should be flushed based on conditions or settings
    if [[ "${YSU_MESSAGE_POSITION:-before}" = "before" ]]; then
        _flush_ysu_buffer
    fi
}

function _flush_ysu_buffer() {
    if [[ -n "$_YSU_BUFFER" ]]; then
        (>&2 printf "$_YSU_BUFFER")
        _YSU_BUFFER=""
    fi
    # Additional mechanism to ensure buffer is cleared at command prompt
    add-zsh-hook precmd _flush_ysu_buffer_if_needed
}

function _flush_ysu_buffer_if_needed() {
    if [[ -n "$_YSU_BUFFER" ]]; then
        (>&2 printf "$_YSU_BUFFER")
        _YSU_BUFFER=""
    fi
}


function ysu_message() {
    local DEFAULT_MESSAGE_FORMAT="${BOLD}${YELLOW}\
Found existing %alias_type for ${PURPLE}\"%command\"${YELLOW}. \
You should use: ${PURPLE}\"%alias\"${NONE}"

    local alias_type_arg="${1}"
    local command_arg="${2}"
    local alias_arg="${3}"

    command_arg="${command_arg//\%/%%}"
    command_arg="${command_arg//\\/\\\\}"

    local MESSAGE="${YSU_MESSAGE_FORMAT:-"$DEFAULT_MESSAGE_FORMAT"}"
    MESSAGE="${MESSAGE//\%alias_type/$alias_type_arg}"
    MESSAGE="${MESSAGE//\%command/$command_arg}"
    MESSAGE="${MESSAGE//\%alias/$alias_arg}"

    _write_ysu_buffer "$MESSAGE\n"
}


function _write_ysu_buffer() {
    _YSU_BUFFER+="$@"
    local position="${YSU_MESSAGE_POSITION:-before}"
    if [[ "$position" = "before" ]]; then
        _flush_ysu_buffer
    elif [[ "$position" != "after" ]]; then
        (>&2 printf "${RED}${BOLD}Unknown value for YSU_MESSAGE_POSITION '$position'. Expected value 'before' or 'after'${NONE}\n")
        _flush_ysu_buffer
    fi
}

function _flush_ysu_buffer() {
    (>&2 printf "$_YSU_BUFFER")
    _YSU_BUFFER=""
}

function ysu_message() {
    local DEFAULT_MESSAGE_FORMAT="${BOLD}${YELLOW}\
Found existing %alias_type for ${PURPLE}\"%command\"${YELLOW}. \
You should use: ${PURPLE}\"%alias\"${NONE}"

    local alias_type_arg="${1}"
    local command_arg="${2}"
    local alias_arg="${3}"

    command_arg="${command_arg//\%/%%}"
    command_arg="${command_arg//\\/\\\\}"

    local MESSAGE="${YSU_MESSAGE_FORMAT:-"$DEFAULT_MESSAGE_FORMAT"}"
    MESSAGE="${MESSAGE//\%alias_type/$alias_type_arg}"
    MESSAGE="${MESSAGE//\%command/$command_arg}"
    MESSAGE="${MESSAGE//\%alias/$alias_arg}"

    _write_ysu_buffer "$MESSAGE\n"
}

function _check_ysu_hardcore() {
    if [[ "$YSU_HARDCORE" = 1 ]]; then
        _write_ysu_buffer "${BOLD}${RED}You Should Use hardcore mode enabled. Use your aliases!${NONE}\n"
        kill -s INT $$
    fi
}

function _check_git_aliases() {
    local typed="$1"
    local expanded="$2"

    if [[ "$typed" = "sudo "* ]]; then
        return
    fi

    if [[ "$typed" = "git "* ]]; then
        local found=false
        git config --get-regexp "^alias\..+$" | sort | while read key value; do
            key="${key#alias.}"
            if [[ -z "$value" ]]; then
                value="${key#* }"
                key="${key%% *}"
            fi

            if [[ "$expanded" = "git $value" || "$expanded" = "git $value "* ]]; then
                ysu_message "git alias" "$value" "git $key"
                found=true
            fi
        done

        if $found; then
            _check_ysu_hardcore
        fi
    fi
}

function _check_global_aliases() {
    local typed="$1"
    local expanded="$2"

    local found=false
    alias -g | sort | while read entry; do
        local tokens=("${(@s/=/)entry}")
        local key="${tokens[1]}"
        local value="${(Q)tokens[2]}"
        if [[ ${YSU_IGNORED_GLOBAL_ALIASES[(r)$key]} == "$key" ]]; then
            continue
        fi

        if [[ "$typed" = *" $value "* || "$typed" = *" $value" || "$typed" = "$value "* || "$typed" = "$value" ]]; then
            ysu_message "global alias" "$value" "$key"
            found=true
        fi
    done

    if $found; then
        _check_ysu_hardcore
    fi
}

function _check_aliases() {
    local typed="$1"
    local expanded="$2"

    local found_aliases=()
    local best_match=""
    local best_match_value=""
    local key
    local value

    if [[ "$typed" = "sudo "* ]]; then
        return
    fi

    for key in "${(@k)aliases}"; do
        value="${aliases[$key]}"
        if [[ ${YSU_IGNORED_ALIASES[(r)$key]} == "$key" ]]; then
            continue
        fi

        if [[ "$typed" = "$value" || "$typed" = "$value "* ]]; then
            if [[ "${#value}" -gt "${#key}" ]]; then
                found_aliases+="$key"
                if [[ "${#value}" -gt "${#best_match_value}" ]]; then
                    best_match="$key"
                    best_match_value="$value"
                elif [[ "${#value}" -eq "${#best_match}" && ${#key} -lt "${#best_match}" ]]; then
                    best_match="$key"
                    best_match_value="$value"
                fi
            fi
        fi
    done

    if [[ "$YSU_MODE" = "ALL" ]]; then
        for key in ${(@ok)found_aliases}; do
            value="${aliases[$key]}"
            ysu_message "alias" "$value" "$key"
        done
    elif [[ (-z "$YSU_MODE" || "$YSU_MODE" = "BESTMATCH") && -n "$best_match" ]]; then
        value="${aliases[$best_match]}"
        if [[ "$typed" = "$best_match" || "$typed" = "$best_match "* ]]; then
            return
        fi
        ysu_message "alias" "$value" "$best_match"
    fi

    if [[ -n "$found_aliases" ]]; then
        _check_ysu_hardcore
    fi
}

function disable_you_should_use() {
    add-zsh-hook -D preexec _check_aliases
    add-zsh-hook -D preexec _check_global_aliases
    add-zsh-hook -D preexec _check_git_aliases
    add-zsh-hook -D precmd _flush_ysu_bufferf
}

function enable_you_should_use() {
    disable_you_should_use
    add-zsh-hook preexec _check_aliases
    add-zsh-hook preexec _check_global_aliases
    add-zsh-hook preexec _check_git_aliases
    add-zsh-hook precmd _flush_ysu_buffer
}

autoload -Uz add-zsh-hook
enable_you_should_use
