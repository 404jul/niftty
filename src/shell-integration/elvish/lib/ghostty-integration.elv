{
  use platform
  use str

  # Clean up XDG_DATA_DIRS by removing GHOSTTY_SHELL_INTEGRATION_XDG_DIR
  if (and (has-env GHOSTTY_SHELL_INTEGRATION_XDG_DIR) (has-env XDG_DATA_DIRS)) {
    set-env XDG_DATA_DIRS (str:replace $E:GHOSTTY_SHELL_INTEGRATION_XDG_DIR":" "" $E:XDG_DATA_DIRS)
    unset-env GHOSTTY_SHELL_INTEGRATION_XDG_DIR
  }

  # List of enabled shell integration features
  var features = [(str:split ',' $E:GHOSTTY_SHELL_FEATURES)]

  # DCS passthrough wrapping for tmux. tmux does not forward unknown
  # OSC sequences (prompt marks, pwd reports) to the outer terminal, so
  # inside tmux every mark we emit is wrapped in tmux's passthrough
  # escape sequence instead: ESC P tmux ; <payload with each ESC
  # doubled> ESC \. Niftty decodes the payload and tmux 3.2+ forwards
  # it; tmux 3.3+ additionally requires the allow-passthrough option,
  # which we enable for our own pane. GHOSTTY_TMUX_PASSTHROUGH covers
  # remote shells reached through `niftty +ssh` from inside a local
  # tmux. Marks degrade to today's behavior (dropped by tmux) when
  # passthrough is unavailable or we're not under a Niftty-attached
  # server. The begin value already contains the doubled ESC for the
  # payload's own leading ESC. Title and cursor shape stay unwrapped:
  # tmux manages those itself.
  var pt-begin = ""
  var pt-end = ""
  {
    var term-program = ""
    if (has-env TERM_PROGRAM) { set term-program = $E:TERM_PROGRAM }
    var in-tmux = (and (has-env TMUX) (not-eq $E:TMUX ""))
    var remote-hint = (and (has-env GHOSTTY_TMUX_PASSTHROUGH) (eq $E:GHOSTTY_TMUX_PASSTHROUGH "1"))
    if (and (has-value $features tmux) (eq $term-program ghostty) (or $in-tmux $remote-hint)) {
      # Pane-scoped, runtime only: never persisted to the user's tmux
      # config. Fails quietly on tmux without the option (3.2, where
      # passthrough is always allowed) or with it disabled by policy.
      if $in-tmux {
        try { e:tmux set-option -p allow-passthrough on >/dev/null 2>/dev/null } catch _ { }
      }
      set pt-begin = "\ePtmux;\e"
      set pt-end = "\e\\"
    }
  }

  # State tracking for semantic prompt sequences
  # Values: 'prompt-start', 'pre-exec', 'post-exec'
  fn set-prompt-state {|new| set-env __ghostty_prompt_state $new }

  fn mark-prompt-start {
    if (not-eq $E:__ghostty_prompt_state 'prompt-start') {
      printf $pt-begin"\e]133;D;aid="$pid"\a"$pt-end
    }
    set-prompt-state 'prompt-start'
    printf $pt-begin"\e]133;A;aid="$pid"\a"$pt-end
  }

  fn mark-output-start {|_|
    set-prompt-state 'pre-exec'
    printf $pt-begin"\e]133;C\a"$pt-end
  }

  fn mark-output-end {|cmd-info|
    set-prompt-state 'post-exec'

    var exit-status = 0

    # in case of error: retrieve exit status,
    # unless does not exist (= builtin function failure), then default to 1
    if (not-eq $nil $cmd-info[error]) {
      set exit-status = 1

      if (has-key $cmd-info[error] reason) {
        if (has-key $cmd-info[error][reason] exit-status) {
          set exit-status = $cmd-info[error][reason][exit-status]
        }
      }
    }

    printf $pt-begin"\e]133;D;"$exit-status";aid="$pid"\a"$pt-end
  }

  # NOTE: OSC 133;B (end of prompt, start of input) cannot be reliably
  # implemented at the script level in Elvish. The prompt function's output is
  # escaped, and writing to /dev/tty has timing issues because Elvish renders
  # its prompts on a background thread. Full semantic prompt support requires a
  # native implementation: https://github.com/elves/elvish/pull/1917

  fn sudo-with-terminfo {|@args|
    var sudoedit = $false
    for arg $args {
      if (str:has-prefix $arg --) {
        if (eq $arg --edit) {
          set sudoedit = $true
          break
        }
      } elif (str:has-prefix $arg -) {
        if (str:contains (str:trim-prefix $arg -) e) {
          set sudoedit = $true
          break
        }
      } elif (not (str:contains $arg =)) {
        break
      }
    }

    if (not $sudoedit) { set args = [ --preserve-env=TERMINFO $@args ] }
    (external sudo) $@args
  }

  # SSH Integration
  #
  # Wrap `ssh` with `niftty +ssh` and translate the shell-integration
  # feature flags into command options.
  fn ssh-integration {|@args|
    var niftty = $E:GHOSTTY_BIN_DIR/"niftty"
    var flags = []
    if (not (has-value $features ssh-env)) {
      set flags = (conj $flags --forward-env=false)
    }
    if (not (has-value $features ssh-terminfo)) {
      set flags = (conj $flags --terminfo=false)
    }
    if (not (has-value $features ssh-integration)) {
      set flags = (conj $flags --shell-integration=false)
    }
    $niftty +ssh $@flags -- $@args
  }

  defer {
    mark-prompt-start
  }

  set edit:before-readline = (conj $edit:before-readline $mark-prompt-start~)
  set edit:after-readline  = (conj $edit:after-readline $mark-output-start~)
  set edit:after-command   = (conj $edit:after-command $mark-output-end~)

  if (str:contains $E:GHOSTTY_SHELL_FEATURES "cursor") {
    var cursor = "5"    # blinking bar
    if (has-value $features cursor:steady) {
      set cursor = "6"  # steady bar
    }

    fn beam  { printf "\e["$cursor" q" }
    fn reset { printf "\e[0 q" }
    set edit:before-readline = (conj $edit:before-readline $beam~)
    set edit:after-readline  = (conj $edit:after-readline {|_| reset })
  }
  if (and (has-value $features path) (has-env GHOSTTY_BIN_DIR)) {
    if (not (has-value $paths $E:GHOSTTY_BIN_DIR)) {
        set paths = [$@paths $E:GHOSTTY_BIN_DIR]
    }
  }
  if (and (has-value $features sudo) (not-eq "" $E:TERMINFO) (has-external sudo)) {
    edit:add-var sudo~ $sudo-with-terminfo~
  }
  if (and (str:contains $E:GHOSTTY_SHELL_FEATURES ssh-) (has-external ssh)) {
    edit:add-var ssh~ $ssh-integration~
  }

  # Report changes to the current directory.
  fn report-pwd { printf $pt-begin"\e]7;kitty-shell-cwd://%s%s\a"$pt-end (platform:hostname) $pwd }
  set after-chdir = (conj $after-chdir {|_| report-pwd })
  report-pwd
}
