# This shell script aims to be written in a way where it can't really fail
# or all failure scenarios are handled, so that we never leave the shell in
# a weird state. If you find a way to break this, please report a bug!

function ghostty_restore_xdg_data_dir -d "restore the original XDG_DATA_DIR value"
    # If we don't have our own data dir then we don't need to do anything.
    if not set -q GHOSTTY_SHELL_INTEGRATION_XDG_DIR
        return
    end

    # If the data dir isn't set at all then we don't need to do anything.
    if not set -q XDG_DATA_DIRS
        return
    end

    # We need to do this so that XDG_DATA_DIRS turns into an array.
    set --function --path xdg_data_dirs "$XDG_DATA_DIRS"

    # If our data dir is in the list then remove it.
    if set --function index (contains --index "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR" $xdg_data_dirs)
        set --erase --function xdg_data_dirs[$index]
    end

    # Re-export our data dir
    if set -q xdg_data_dirs[1]
        set --global --export --unpath XDG_DATA_DIRS "$xdg_data_dirs"
    else
        set --erase --global XDG_DATA_DIRS
    end

    set --erase GHOSTTY_SHELL_INTEGRATION_XDG_DIR
end

function ghostty_exit -d "exit the shell integration setup"
    functions -e ghostty_restore_xdg_data_dir
    functions -e ghostty_exit
    exit 0
end

# We always try to restore the XDG data dir
ghostty_restore_xdg_data_dir

# Remember our integration dir before it was removed from XDG_DATA_DIRS
# above, so the tmux wrapper below can re-export it for pane shells.
if set -q GHOSTTY_SHELL_INTEGRATION_XDG_DIR
    set -g __ghostty_xdg_integ_dir $GHOSTTY_SHELL_INTEGRATION_XDG_DIR
end

# If we aren't interactive or we've already run, don't run.
status --is-interactive || ghostty_exit

# We do the full setup on the first prompt render. We do this so that other
# shell integrations that setup the prompt and modify things are able to run
# first. We want to run _last_.
function __ghostty_setup --on-event fish_prompt -d "Setup ghostty integration"
    functions -e __ghostty_setup

    set --local features (string split , $GHOSTTY_SHELL_FEATURES)

    # Parse the fish version for feature detection.
    # Default to 0.0 if version is unavailable or malformed.
    set -l fish_major 0
    set -l fish_minor 0
    if set -q version[1]
        set -l fish_ver (string match -r '(\d+)\.(\d+)' -- $version[1])
        if set -q fish_ver[2]; and test -n "$fish_ver[2]"
            set fish_major "$fish_ver[2]"
        end
        if set -q fish_ver[3]; and test -n "$fish_ver[3]"
            set fish_minor "$fish_ver[3]"
        end
    end

    # Our OSC133A (prompt start) sequence. If we're using Fish >= 4.1
    # then it supports click_events so we enable that.
    set -g __ghostty_prompt_start_mark "\e]133;A\a"
    if test "$fish_major" -gt 4; or test "$fish_major" -eq 4 -a "$fish_minor" -ge 1
        set -g __ghostty_prompt_start_mark "\e]133;A;click_events=1\a"
    end

    # DCS passthrough wrapping for tmux. tmux does not forward unknown
    # OSC sequences (prompt marks, pwd reports) to the outer terminal,
    # so inside tmux every mark we emit is wrapped in tmux's passthrough
    # escape sequence instead: ESC P tmux ; <payload with each ESC
    # doubled> ESC \. Niftty decodes the payload and tmux 3.2+ forwards
    # it; tmux 3.3+ additionally requires the allow-passthrough option,
    # which we enable for our own pane. GHOSTTY_TMUX_PASSTHROUGH covers
    # remote shells reached through `niftty +ssh` from inside a local
    # tmux. Marks degrade to today's behavior (dropped by tmux) when
    # passthrough is unavailable or we're not under a Niftty-attached
    # server. The begin value already contains the doubled ESC for the
    # payload's own leading ESC. The bytes are backslash escapes here
    # (echo -en processes them at emission), matching every other
    # marked string above. Title and cursor shape stay unwrapped: tmux
    # manages those itself.
    set -g __ghostty_pt_begin ""
    set -g __ghostty_pt_end ""
    if contains tmux $features
        and test "$TERM_PROGRAM" = ghostty
        and test -n "$TMUX" -o "$GHOSTTY_TMUX_PASSTHROUGH" = 1
        if test -n "$TMUX"
            # Pane-scoped, runtime only: never persisted to the user's
            # tmux config. Fails quietly on tmux without the option
            # (3.2, where passthrough is always allowed) or with it
            # disabled by policy.
            command tmux set-option -p allow-passthrough on 2>/dev/null
        end
        set -g __ghostty_pt_begin "\ePtmux;\e"
        set -g __ghostty_pt_end "\e\\"
        set -g __ghostty_prompt_start_mark "$__ghostty_pt_begin"$__ghostty_prompt_start_mark"$__ghostty_pt_end"
    end

    if string match -q 'cursor*' -- $features
        set -l cursor 5                                   # blinking bar
        contains cursor:steady $features && set cursor 6  # steady bar

        # Change the cursor to a beam on prompt.
        function __ghostty_set_cursor_beam --on-event fish_prompt -V cursor -d "Set cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[$cursor q"
            end
        end
        function __ghostty_reset_cursor --on-event fish_preexec -d "Reset cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[0 q"
            end
        end
    end

    # Add Ghostty binary to PATH if the path feature is enabled
    if contains path $features; and test -n "$GHOSTTY_BIN_DIR"
        fish_add_path --global --path --append "$GHOSTTY_BIN_DIR"
    end

    # When using sudo shell integration feature, ensure $TERMINFO is set
    # and `sudo` is not already a function or alias
    if contains sudo $features; and test -n "$TERMINFO"; and test file = (type -t sudo 2> /dev/null; or echo "x")
        # Wrap `sudo` command to ensure Ghostty terminfo is preserved
        function sudo -d "Wrap sudo to preserve terminfo"
            set --function sudo_has_sudoedit_flags no
            for arg in $argv
                # Check if argument is '-e' or '--edit' (sudoedit flags)
                if string match -q -- -e "$arg"; or string match -q -- --edit "$arg"
                    set --function sudo_has_sudoedit_flags yes
                    break
                end
                # Check if argument is neither an option nor a key-value pair
                if not string match -r -q -- "^-" "$arg"; and not string match -r -q -- "=" "$arg"
                    break
                end
            end
            if test "$sudo_has_sudoedit_flags" = yes
                command sudo $argv
            else
                command sudo --preserve-env=TERMINFO $argv
            end
        end
    end

    # SSH Integration
    #
    # Wrap `ssh` with `niftty +ssh` and translate the shell-integration
    # feature flags into command options.
    set -l features (string split ',' -- "$GHOSTTY_SHELL_FEATURES")
    if contains ssh-env $features; or contains ssh-terminfo $features; or contains ssh-integration $features
        function ssh --wraps=ssh --description "SSH wrapper with Niftty integration"
            set -l features (string split ',' -- "$GHOSTTY_SHELL_FEATURES")
            set -l flags
            contains ssh-env $features; or set -a flags --forward-env=false
            contains ssh-terminfo $features; or set -a flags --terminfo=false
            contains ssh-integration $features; or set -a flags --shell-integration=false
            "$GHOSTTY_BIN_DIR/niftty" +ssh $flags -- $argv
        end
    end

    # Tmux Integration
    #
    # Wrap `tmux` so shells in panes it creates load Niftty shell
    # integration: pane shells autoload it from XDG_DATA_DIRS, which we
    # removed from our own environment after loading (see
    # ghostty_restore_xdg_data_dir). A server started by this invocation
    # inherits the re-exported value; a server that is already running
    # gets it in its global environment so windows created later
    # integrate too. `set-environment` fails quietly when no server is
    # running, which is fine: the prefixed invocation that follows
    # starts one with the right environment.
    if contains tmux $features; and test -n "$__ghostty_xdg_integ_dir"
        function tmux --wraps=tmux --description "tmux wrapper with Niftty integration"
            set -l xdg
            if set -q XDG_DATA_DIRS[1]
                set xdg $XDG_DATA_DIRS
            else
                set xdg /usr/local/share /usr/share
            end
            set -l xdg_with_niftty "$__ghostty_xdg_integ_dir:"(string join : $xdg)
            command tmux set-environment -g XDG_DATA_DIRS "$xdg_with_niftty" 2>/dev/null
            XDG_DATA_DIRS="$xdg_with_niftty" command tmux $argv
        end
    end

    # Setup prompt marking
    function __ghostty_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
        # If we never got the output end event, then we need to send it now.
        if test "$__ghostty_prompt_state" != prompt-start
            echo -en "$__ghostty_pt_begin\e]133;D\a$__ghostty_pt_end"
        end

        set --global __ghostty_prompt_state prompt-start
        echo -en $__ghostty_prompt_start_mark
    end

    function __ghostty_mark_output_start --on-event fish_preexec
        set --global __ghostty_prompt_state pre-exec
        echo -en "$__ghostty_pt_begin\e]133;C\a$__ghostty_pt_end"
    end

    function __ghostty_mark_output_end --on-event fish_postexec
        set --global __ghostty_prompt_state post-exec
        echo -en "$__ghostty_pt_begin\e]133;D;$status\a$__ghostty_pt_end"
    end

    # Report pwd. This is actually built-in to fish but only for terminals
    # that match an allowlist and that isn't us.
    function __update_cwd_osc --on-variable PWD -d 'Notify capable terminals when $PWD changes'
        if status --is-command-substitution || set -q INSIDE_EMACS
            return
        end
        printf "$__ghostty_pt_begin"\e\]7\;file://%s%s\a"$__ghostty_pt_end" $hostname (string escape --style=url $PWD)
    end

    # Enable fish to handle reflow because Ghostty clears the prompt on resize.
    set --global fish_handle_reflow 1

    # Initial calls for first prompt
    if string match -q 'cursor*' -- $features
        __ghostty_set_cursor_beam
    end
    __ghostty_mark_prompt_start
    __update_cwd_osc
end

ghostty_exit
