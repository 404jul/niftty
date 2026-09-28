const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const Action = @import("ghostty.zig").Action;
const DiskCache = @import("ssh_cache.zig").DiskCache;
const ssh_session = @import("ssh_session.zig");
const ssh_tunnel = @import("ssh_tunnel.zig");
const ssh_mux = @import("ssh_mux.zig");

const internal_os = @import("../os/main.zig");
const terminfopkg = @import("../terminfo/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.ssh);

const usage =
    \\Usage: niftty +ssh [flags] [--] <ssh args...>
    \\
    \\Flags:
    \\  --forward-env[=bool]  Enable TERM / SendEnv forwarding. Default: true.
    \\  --terminfo[=bool]     Install Ghostty terminfo on first connect. Default: true.
    \\  --shell-integration[=bool] Install and load Niftty's zsh/bash shell
    \\                        integration on the remote host. Default: true.
    \\  --auto-forward[=bool] Enable automatic local forwarding. Default: true.
    \\  --forward-notify[=bool] Show automatic forwarding notifications. Default: true.
    \\  --cache[=bool]        Use the remote setup cache. Default: true.
    \\  --ssh=<path>          Path to the ssh binary. Default: first `ssh` on PATH.
    \\  --cwd=<path>         Start the interactive remote shell in this directory.
    \\  --verbose             Print +ssh status lines to stderr.
    \\  --help                Show full help.
    \\
    \\ssh flags and the destination go after +ssh's own flags (or after `--`).
    \\
;

pub const Options = struct {
    /// Set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Maps to the `ssh-env` shell integration feature.
    @"forward-env": bool = true,

    /// Maps to the `ssh-terminfo` shell integration feature.
    terminfo: bool = true,

    /// Maps to the `ssh-integration` shell integration feature.
    @"shell-integration": bool = true,

    /// When false, both cache read and write are bypassed.
    cache: bool = true,
    /// Detect and locally forward remote development ports.
    @"auto-forward": bool = true,

    /// Notify when an automatic forward is created.
    @"forward-notify": bool = true,

    /// The wrapped `ssh` binary.
    /// `/`-containing values are treated as paths; otherwise resolved via PATH.
    ssh: []const u8 = "ssh",

    /// Initial working directory for the interactive remote shell.
    /// Inserted as a `cd` before the login shell starts; ignored when
    /// the ssh args request a remote command. Used by the app so a
    /// split pane opens where the pane it split from was.
    cwd: ?[]const u8 = null,

    /// When true, print verbose output to stderr.
    verbose: bool = false,

    /// Arguments passed through to `ssh` verbatim. Populated by
    /// `parseManuallyHook` when we reach the first non-flag argument (or
    /// an explicit `--`).
    _ssh_args: std.ArrayList([]const u8) = .empty,

    /// Enables arg parsing diagnostics so unknown flags become
    /// diagnostics rather than fatal errors.
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(_: Options) !void {
        return Action.help_error;
    }

    /// Manual parse hook. For each argument:
    ///   - If it's a literal `--`, consume everything after it as ssh
    ///     args and stop parsing.
    ///   - If it doesn't start with `--`, this is the start of the ssh
    ///     argv. Consume this arg and everything after as ssh args and
    ///     stop parsing.
    ///   - Otherwise (a `--foo` arg), return true so the generic parser
    ///     handles it as one of our own flags.
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) Allocator.Error!bool {
        if (std.mem.eql(u8, arg, "--")) {
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        if (!std.mem.startsWith(u8, arg, "--")) {
            try self._ssh_args.append(alloc, try alloc.dupe(u8, arg));
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }

        return true;
    }
};

/// Wrap `ssh` to automatically configure Ghostty terminal integration on
/// remote hosts.
///
/// Any arguments that aren't recognized as `+ssh` flags are passed to
/// the real `ssh` binary unchanged. You can use `--` as an explicit
/// disambiguator if needed, though it's almost never required: `ssh`
/// has no long flags, and `+ssh` defines no short flags, so there's
/// nothing to collide.
///
/// This is typically called by every supported Ghostty shell integration.
/// Each shell defines an `ssh` function that runs:
///
///     niftty +ssh <flags> -- "$@"
///
/// You can also run `niftty +ssh` directly, or alias it yourself (e.g.
/// `alias ssh='niftty +ssh --'`) if you prefer not to use the shell
/// integration.
///
/// `+ssh` also keeps one connection-scoped control socket for uploads.
/// Panes that resolve to the same `user@host:port` share one ControlMaster.
/// It performs up to five pieces of setup:
///   1. **Environment forwarding** (`--forward-env`). Sets `TERM` to
///      `xterm-256color` and requests `SendEnv` forwarding of
///      `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` so the
///      remote shell can still detect that it's running inside Niftty.
///      The remote `sshd_config` must list these in `AcceptEnv` for
///      forwarding to succeed.
///
///   2. **Terminfo install** (`--terminfo`). On the first connection to a
///      given destination, installs Ghostty's embedded terminfo entry on the
///      remote host with `tic -x -` during the one-time remote setup (see
///      below). When terminfo is successfully installed or already cached,
///      `TERM` is set to `xterm-ghostty` instead of `xterm-256color`.
///
///   3. **Shell integration** (`--shell-integration`). On the first
///      connection to a given destination, installs Niftty's zsh and bash
///      shell integration under
///      `~/.local/share/niftty/shell-integration/<hash>` during the
///      one-time remote setup. Interactive logins then start the remote
///      login shell with that integration loaded (zsh via `ZDOTDIR`, bash
///      via `--posix` and `ENV`, as local shells do), so prompt marks
///      (OSC 133) and command history for inline predictions work over
///      SSH. `GHOSTTY_PREDICTION` and the `cursor`, `title`, and `tmux`
///      entries of `GHOSTTY_SHELL_FEATURES` are carried over from the
///      local shell. Bash 3 (e.g. Apple's `/bin/bash`, which ignores `ENV`
///      in POSIX mode) and other login shells start unchanged. When this
///      `+ssh` itself runs inside a local tmux, the remote integration
///      wraps its marks in tmux's passthrough (and the cwd reporter's
///      OSC 7 is wrapped the same way) so they reach Niftty through it.
///      With the `tmux` feature the remote zsh integration also gets its
///      integration dir, so a tmux started on the remote host integrates
///      its panes too.
///
///   4. **Port forwarding** (`--auto-forward`). Detects listening
///      unprivileged TCP ports on the remote host, including ports that
///      were already open when the session started, and forwards them to
///      loopback locally. A port qualifies when its owning process is
///      interactive (fd 0 is a TTY, so it was started from a user shell —
///      any bind address) or when it listens on loopback / all-interfaces
///      (covering daemonized dev services like docker-proxy); common infra
///      ports (databases, rpcbind, ...) are skipped. The same port is
///      preferred; if it is occupied, Niftty chooses an available local
///      port. On macOS, the SSH Ports overlay lists these tunnels and can
///      add or close them. Closing a tunnel suppresses its port only while
///      it stays listening; once the remote listener is gone the port
///      becomes eligible again.
///
///   5. **Working directory reporting**. Interactive logins (no remote
///      command) inject a POSIX middleman that runs the login shell as
///      a child, polls that child's cwd, and emits OSC 7 with host
///      `niftty-ssh`. The watcher is the parent so Linux Yama allows
///      `/proc/<child>/cwd`. Unresolved `lsof` `readlink:` paths are
///      discarded. The parent `wait`s the shell once so the session
///      exits. Skipped when a remote command is given, or with
///      `-N`/`-T`/`-W`. Backgrounding reassigns the subshell's stdin to
///      `/dev/null`, so before starting the subshell the middleman dups
///      its own stdin (the pty sshd opened on the remote device path) to
///      fd 9, and the login shell's stdin/stdout/stderr are dup'd back
///      from fd 9. The shell thus sits on the same open file description
///      as sshd's pty, so `ttyname()` reports the real pts path. This
///      cannot be done by opening `/dev/tty`: that names the
///      controlling-terminal device (5:0), and tmux 3.7+ rejects clients
///      whose terminal name is `/dev/tty` ("open terminal failed: can't
///      use /dev/tty") because its server runs in a different session
///      where `/dev/tty` resolves elsewhere.
///
/// The terminfo and shell integration installs share one short-lived
/// `ControlMaster` connection that feeds a POSIX setup script to
/// `/bin/sh -s` on the remote host. The combined result is cached per
/// destination (see `niftty +ssh-cache`) and only recorded when every
/// requested part succeeded, so subsequent connections skip the setup.
///
/// If the terminfo install fails (e.g. `tic` not available on the
/// remote, filesystem permissions), a warning is logged and the
/// connection continues with `TERM=xterm-256color`. If the shell
/// integration install fails, a warning is logged and the login shell
/// starts without it.
///
/// Flags:
///
///   * `--forward-env=<bool>`: Enable `TERM` / `SendEnv` environment
///     forwarding. Default: `true`.
///
///   * `--terminfo=<bool>`: Enable automatic terminfo install on first
///     connection. Default: `true`.
///
///   * `--shell-integration=<bool>`: Enable automatic install and loading
///     of Niftty's zsh/bash shell integration on the remote host.
///     Default: `true`.
///
///   * `--auto-forward=<bool>`: Enable automatic local forwarding of
///     remote development ports. Default: `true`.
///
///   * `--forward-notify=<bool>`: Show a desktop notification when a
///     forward is created. Independent of `--auto-forward`. Default: `true`.
///
///   * `--cache=<bool>`: Use the remote setup cache. Default: `true`.
///     When `false`, both the cache read (skip-if-installed) and the
///     cache write (record-on-success) are bypassed, and every
///     connection performs the install. To one-shot reinstall a single
///     host while keeping the cache in use, prefer `niftty +ssh-cache
///     --remove=<host>` followed by a normal connection.
///
///   * `--ssh=<path>`: Path to the `ssh` binary to execute. Default: the
///     first `ssh` found on `PATH`.
///   * `--cwd=<path>`: Start the interactive remote shell in this
///     directory (ignored when a remote command is requested). The `cd`
///     is best-effort: an unreadable directory falls back to the default.
///     Used by the app to open split panes in the directory of the pane
///     they were split from.
///
///   * `--verbose`: Print +ssh status lines to stderr, and surface
///     remote stderr during the remote setup.
///
/// Examples:
///
///     # Basic invocation using defaults:
///     niftty +ssh user@example.com
///
///     # Forward Ghostty env vars but skip the terminfo install:
///     niftty +ssh --terminfo=false user@example.com
///
///     # `ssh` flags (short-form `-p`, etc.) pass through unchanged:
///     niftty +ssh -p 2222 -i ~/.ssh/id_ed25519 user@example.com
///
///     # Use `--` explicitly if your ssh args might collide with our flags:
///     niftty +ssh -- --some-rare-ssh-arg user@example.com
///
/// Pass `--verbose` to see what `+ssh` is doing. For cache inspection
/// and management, see `niftty +ssh-cache`.
///
/// Available since: 1.4.0
pub fn run(alloc_gpa: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try cli_args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        try cli_args.parse(Options, alloc_gpa, &opts, &iter);
    }

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Any diagnostic from the arg parser is an unknown flag or bad
    // value. Reject loudly — silently forwarding `--typo` to ssh would
    // produce confusing downstream errors.
    if (!opts._diagnostics.empty()) {
        for (opts._diagnostics.items()) |diag| {
            if (diag.key.len > 0) {
                stderr.print(
                    "Error: unknown flag `--{s}`.\n",
                    .{diag.key},
                ) catch {};
            } else {
                stderr.print("Error: {s}\n", .{diag.message}) catch {};
            }
        }
        stderr.print("\n{s}", .{usage}) catch {};
        stderr.flush() catch {};
        return 2;
    }

    const result = runInner(alloc_gpa, &opts, stderr);

    stderr.flush() catch {};
    return result;
}

fn runInner(
    gpa: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (opts._ssh_args.items.len == 0) {
        try stderr.print("Error: no ssh arguments provided.\n\n{s}", .{usage});
        return 2;
    }

    const g_out = sshGStdout(alloc, opts.ssh, opts._ssh_args.items);
    const destination = if (g_out) |stdout| parseDestination(alloc, stdout) else null;
    const mux_key = if (g_out) |stdout| ssh_mux.keyFromG(alloc, stdout) else null;

    const wanted: SetupParts = .{
        .terminfo = opts.terminfo,
        .integration = opts.@"shell-integration",
    };
    const si_version = integrationVersion(&integration_files);
    const cache_version = try cacheVersion(alloc, wanted, terminfopkg.version, &si_version);

    const session: struct {
        term: []const u8,
        to_cache: ?struct { cache: DiskCache, dest: []const u8 } = null,
    } = session: {
        if (!wanted.any()) break :session .{ .term = "xterm-256color" };

        const dest = destination orelse {
            warnPrint(stderr, "could not resolve ssh destination; skipping remote setup", .{});
            break :session .{ .term = "xterm-256color" };
        };

        const cache: ?DiskCache = if (opts.cache) cache: {
            const path = DiskCache.defaultPath(alloc, "niftty") catch |err| {
                warnPrint(stderr, "niftty +ssh cache unavailable: {t}", .{err});
                break :session .{ .term = "xterm-256color" };
            };
            break :cache .{ .path = path };
        } else null;

        if (cache) |c| {
            const cached = c.contains(
                alloc,
                dest,
                cache_version,
            ) catch |err| cached: {
                if (DiskCache.isFailure(err)) warnPrint(
                    stderr,
                    "unable to read the cache '{s}': {t}",
                    .{ c.path, err },
                );
                break :cached false;
            };

            if (cached) {
                verbosePrint(opts, stderr, "dest: {s} (cached, skipping install)", .{dest});
                break :session .{
                    .term = if (wanted.terminfo) "xterm-ghostty" else "xterm-256color",
                };
            } else {
                verbosePrint(opts, stderr, "dest: {s} (not cached, will install)", .{dest});
            }
        } else {
            verbosePrint(opts, stderr, "dest: {s} (cache disabled, will install)", .{dest});
        }

        const what: []const u8 = if (!wanted.integration)
            "xterm-niftty +terminfo"
        else if (!wanted.terminfo)
            "shell integration"
        else
            "xterm-niftty +terminfo and shell integration";
        stderr.print("Setting up {s} on {s}...\n", .{ what, dest }) catch {};
        stderr.flush() catch {};

        const failed = runRemoteSetup(alloc, opts, stderr, wanted, &si_version);
        if (failed.terminfo) warnPrint(stderr, "failed to install terminfo", .{});
        if (failed.integration) warnPrint(stderr, "failed to install shell integration", .{});
        break :session .{
            .term = if (wanted.terminfo and !failed.terminfo) "xterm-ghostty" else "xterm-256color",
            .to_cache = if (failed.any()) null else if (cache) |c| .{ .cache = c, .dest = dest } else null,
        };
    };

    // Build the full argv: [ssh, ...our opts, ...user args]
    const env_opts: []const []const u8 = if (opts.@"forward-env") env_opts: {
        const set_term = try std.fmt.allocPrint(
            alloc,
            "SetEnv=TERM={s}",
            .{session.term},
        );
        break :env_opts &.{
            "-o", set_term,
            "-o", "SendEnv=COLORTERM",
            "-o", "SendEnv=TERM_PROGRAM",
            "-o", "SendEnv=TERM_PROGRAM_VERSION",
        };
    } else &.{};
    const mux: ?ssh_mux.Session = if (destination) |dest|
        try prepareMux(alloc, opts.ssh, dest, mux_key)
    else
        null;
    const control_opts: []const []const u8 = if (mux) |m| try controlOpts(alloc, m) else &.{};

    const inject_cwd = shouldInjectCwdReporter(opts._ssh_args.items);
    const in_tmux = if (localEnv(alloc, "TMUX")) |v| v.len > 0 else false;
    const tty_opts: []const []const u8 = if (inject_cwd)
        &.{ "-o", "RequestTTY=force" }
    else
        &.{};
    const cwd_cmd: []const []const u8 = if (inject_cwd) &.{try cwdReporterCommand(
        alloc,
        opts.cwd,
        if (wanted.integration) try integrationLauncher(
            alloc,
            &si_version,
            localEnv(alloc, "GHOSTTY_PREDICTION"),
            localEnv(alloc, "GHOSTTY_SHELL_FEATURES") orelse "",
            in_tmux,
        ) else null,
        in_tmux,
    )} else &.{};
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        control_opts,
        env_opts,
        tty_opts,
        opts._ssh_args.items,
        cwd_cmd,
    });
    if (inject_cwd) verbosePrint(opts, stderr, "cwd reporter: injecting niftty OSC 7 middleman", .{});
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    const exit_code = runInteractiveSession(
        gpa,
        opts,
        argv,
        mux,
    ) catch |err| {
        try stderr.print("Error: failed to run {s}: {t}\n", .{ argv[0], err });
        return 1;
    };
    verbosePrint(opts, stderr, "exit: {d}", .{exit_code});

    // Attempt to cache (if needed) on a successful ssh execution.
    if (exit_code == 0) if (session.to_cache) |entry| {
        if (entry.cache.add(
            alloc,
            entry.dest,
            cache_version,
            std.Io.Timestamp.now(global.io(), .real).toSeconds(),
        )) |_| {
            verbosePrint(opts, stderr, "cache: wrote {s}", .{entry.dest});
        } else |err| {
            if (DiskCache.isFailure(err)) {
                warnPrint(
                    stderr,
                    "unable to add '{s}' to the cache '{s}': {t}",
                    .{ entry.dest, entry.cache.path, err },
                );
            } else {
                verbosePrint(
                    opts,
                    stderr,
                    "cache: skipped {s}: {t}",
                    .{ entry.dest, err },
                );
            }
        }
    };

    return exit_code;
}

/// Log to `.ssh` and, if `--verbose`, also print to stderr.
fn verbosePrint(
    opts: *const Options,
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.debug(fmt, args);
    if (!opts.verbose) return;
    stderr.print("+ssh: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// Log a warning and also print a `Warning: <msg>` line to stderr.
fn warnPrint(
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.warn(fmt, args);
    stderr.print("Warning: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}

/// Space-joined items, formattable as `{f}`.
const Joined = struct {
    items: []const []const u8,

    pub fn format(self: Joined, writer: *std.Io.Writer) !void {
        for (self.items, 0..) |a, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.writeAll(a);
        }
    }

    test {
        const testing = std.testing;
        var buf: [128]u8 = undefined;
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{} }});
            try testing.expectEqualStrings("", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{"only"} }});
            try testing.expectEqualStrings("only", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{ "a", "b", "c" } }});
            try testing.expectEqualStrings("a b c", buf[0..w.end]);
        }
    }
};

fn checkExit(term: std.process.Child.Term, label: []const u8) error{ChildFailed}!void {
    switch (term) {
        .exited => |rc| if (rc != 0) {
            log.warn("{s} exited with non-zero status: {d}", .{ label, rc });
            return error.ChildFailed;
        },
        else => {
            log.warn("{s} terminated abnormally: {}", .{ label, term });
            return error.ChildFailed;
        },
    }
}

/// Run `ssh -G <args>` and return stdout, or null if it fails.
fn sshGStdout(
    alloc: Allocator,
    ssh: []const u8,
    args: []const []const u8,
) ?[]const u8 {
    const argv = std.mem.concat(alloc, []const u8, &.{
        &.{ ssh, "-G" },
        args,
    }) catch return null;
    const result = std.process.run(
        alloc,
        global.io(),
        .{ .argv = argv },
    ) catch |err| {
        log.warn("ssh -G spawn failed: {}", .{err});
        return null;
    };
    checkExit(result.term, "ssh -G") catch return null;
    return result.stdout;
}

fn resolveDestination(
    alloc: Allocator,
    ssh: []const u8,
    args: []const []const u8,
) ?[]const u8 {
    return parseDestination(alloc, sshGStdout(alloc, ssh, args) orelse return null);
}

/// Parse `ssh -G` output for `user` and `hostname` and return the
/// formatted `user@hostname`. Returns null if either key is missing
/// or formatting fails.
fn parseDestination(alloc: Allocator, stdout: []const u8) ?[]const u8 {
    var user: []const u8 = "";
    var host: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "user")) {
            user = value;
        } else if (std.mem.eql(u8, key, "hostname")) {
            host = value;
        }
        if (user.len > 0 and host.len > 0) break;
    }

    if (user.len == 0) {
        log.warn("ssh -G output missing user", .{});
        return null;
    }
    if (host.len == 0) {
        log.warn("ssh -G output missing hostname", .{});
        return null;
    }

    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ user, host }) catch null;
}

/// Build a ControlPath short enough for macOS Unix sockets.
/// Darwin `sockaddr_un.sun_path` is 104 bytes including NUL, and OpenSSH
/// may append a connection hash (`'.' + ~16 bytes`). Keep the path under 80.
/// Uses the same 16-byte random basename as other Ghostty temp paths so a
/// `/tmp` fallback is not guessable.
fn allocControlSocketPath(alloc: Allocator) ![]u8 {
    const in_tmp = try internal_os.randomTmpPath(alloc, "gs-");
    if (in_tmp.len <= 80) return in_tmp;
    const base = std.fs.path.basename(in_tmp);
    const fallback = try std.fmt.allocPrint(alloc, "/tmp/{s}", .{base});
    alloc.free(in_tmp);
    return fallback;
}

fn controlSocketPath(alloc: Allocator, tmp: []const u8, basename: []const u8) ![]u8 {
    const in_tmp = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        tmp,
        std.fs.path.sep,
        basename,
    });
    if (in_tmp.len <= 80) return in_tmp;
    alloc.free(in_tmp);
    return std.fmt.allocPrint(alloc, "/tmp/{s}", .{basename});
}

test "control socket path stays in TMPDIR when short" {
    const testing = std.testing;
    const path = try controlSocketPath(testing.allocator, "/tmp", "gs-AAAAAAAAAAAAAAAAAAAAAA");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/gs-AAAAAAAAAAAAAAAAAAAAAA", path);
    try testing.expect(path.len + 17 < 104);
}

test "control socket path falls back when TMPDIR is long" {
    const testing = std.testing;
    const tmp = "/var/folders/7b/c3cgby6d2kbcxq8_nnfny3w80000gn/T/very-long-tmpdir-component";
    const path = try controlSocketPath(testing.allocator, tmp, "gs-AAAAAAAAAAAAAAAAAAAAAA");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/gs-AAAAAAAAAAAAAAAAAAAAAA", path);
    try testing.expect(path.len + 17 < 104);
}

/// The parts of the one-time remote setup. Also used for the parts that
/// failed, mirroring the setup script's exit status bitmask.
const SetupParts = packed struct {
    /// Exit status bit 1.
    terminfo: bool = false,
    /// Exit status bit 2.
    integration: bool = false,

    fn any(self: SetupParts) bool {
        return self.terminfo or self.integration;
    }
};

/// A shell integration file installed on remote hosts. `path` is relative
/// to the remote install dir and mirrors the local resources layout, since
/// each script locates its siblings relative to its own path.
const IntegrationFile = struct {
    path: []const u8,
    contents: []const u8,
};

/// Niftty's zsh and bash shell integration, as installed by
/// `--shell-integration`. The order is fixed: it feeds `integrationVersion`.
const integration_files = [_]IntegrationFile{
    .{ .path = "zsh/.zshenv", .contents = @embedFile("../shell-integration/zsh/.zshenv") },
    .{ .path = "zsh/ghostty-integration", .contents = @embedFile("../shell-integration/zsh/ghostty-integration") },
    .{ .path = "bash/ghostty.bash", .contents = @embedFile("../shell-integration/bash/ghostty.bash") },
    .{ .path = "bash/bash-preexec.sh", .contents = @embedFile("../shell-integration/bash/bash-preexec.sh") },
};

/// Remote parent of the versioned shell integration install dirs. Expanded
/// by the remote `/bin/sh`, inside double quotes.
const integration_remote_root = "$HOME/.local/share/niftty/shell-integration";

/// Quoted heredoc delimiter for the setup script payloads. Payloads that
/// contain it as a whole line are refused (see `heredocSafe`).
const setup_heredoc_delim = "NIFTTY_SETUP_EOF_5B0D3C";

/// Content-derived version of the shell integration payload: 16 lowercase
/// hex chars of Wyhash over every file's relative path and contents. Names
/// the remote install dir, so a changed payload installs side by side.
fn integrationVersion(files: []const IntegrationFile) [16]u8 {
    var hasher = std.hash.Wyhash.init(0);
    for (files) |file| {
        hasher.update(file.path);
        hasher.update(&.{0});
        hasher.update(file.contents);
        hasher.update(&.{0});
    }
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{hasher.final()}) catch unreachable;
    return out;
}

/// The per-destination cache version for the requested setup parts. One
/// cache entry per destination records every part installed with it, so a
/// change to either payload (or to the requested parts) is a cache miss.
fn cacheVersion(
    alloc: Allocator,
    wanted: SetupParts,
    terminfo_version: []const u8,
    integration_version: []const u8,
) Allocator.Error![]const u8 {
    if (!wanted.integration) return terminfo_version;
    if (!wanted.terminfo) return std.fmt.allocPrint(alloc, "si-{s}", .{integration_version});
    return std.fmt.allocPrint(alloc, "{s}+si-{s}", .{ terminfo_version, integration_version });
}

/// True when `body` can be emitted as a quoted heredoc: no line of it may
/// equal the delimiter, or the heredoc would end early and the rest of the
/// payload would run as shell commands.
fn heredocSafe(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, setup_heredoc_delim)) return false;
    }
    return true;
}

fn writeHeredocBody(w: *std.Io.Writer, body: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(body);
    if (body.len > 0 and body[body.len - 1] != '\n') try w.writeByte('\n');
    try w.writeAll(setup_heredoc_delim ++ "\n");
}

/// The POSIX sh script fed to the remote `/bin/sh -s`. It installs the
/// `wanted` parts and exits with a bitmask of the parts that failed
/// (1 = terminfo, 2 = shell integration). The script is the shell's stdin,
/// so no command in it may read stdin other than through its own heredoc.
/// A payload that cannot be quoted safely fails its part up front.
fn remoteSetupScript(
    alloc: Allocator,
    wanted: SetupParts,
    terminfo: []const u8,
    files: []const IntegrationFile,
    integration_version: []const u8,
    verbose: bool,
) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    writeRemoteSetupScript(
        &out.writer,
        wanted,
        terminfo,
        files,
        integration_version,
        verbose,
    ) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeRemoteSetupScript(
    w: *std.Io.Writer,
    wanted: SetupParts,
    terminfo: []const u8,
    files: []const IntegrationFile,
    integration_version: []const u8,
    verbose: bool,
) std.Io.Writer.Error!void {
    // Under --verbose, let remote stderr through (the `tic` step is the
    // most common failure source).
    const quiet = if (verbose) "" else " 2>/dev/null";
    const delim = setup_heredoc_delim;

    try w.writeAll("rc=0\n");
    if (wanted.terminfo) {
        if (heredocSafe(terminfo)) {
            try w.print(
                "if command -v tic >/dev/null 2>&1 && mkdir -p ~/.terminfo 2>/dev/null && tic -x -{s} <<'{s}'\n",
                .{ quiet, delim },
            );
            try writeHeredocBody(w, terminfo);
            try w.writeAll("then :; else rc=$((rc | 1)); fi\n");
        } else {
            try w.writeAll("rc=$((rc | 1))\n");
        }
    }
    if (wanted.integration) {
        const safe = for (files) |file| {
            if (!heredocSafe(file.contents)) break false;
        } else true;
        if (safe) {
            // The `ok` marker goes last: the login launcher only loads an
            // install whose every file was written.
            try w.print("d=\"{s}/{s}\"\n", .{ integration_remote_root, integration_version });
            try w.print("if rm -f \"$d/ok\"{s} && mkdir -p \"$d/zsh\" \"$d/bash\"{s}; then\n", .{ quiet, quiet });
            try w.writeAll("si=0\n");
            for (files) |file| {
                try w.print("cat >\"$d/{s}\"{s} <<'{s}' || si=1\n", .{ file.path, quiet, delim });
                try writeHeredocBody(w, file.contents);
            }
            try w.print("if [ \"$si\" = 0 ] && touch \"$d/ok\"{s}; then :; else rc=$((rc | 2)); fi\n", .{quiet});
            try w.writeAll("else rc=$((rc | 2)); fi\n");
        } else {
            try w.writeAll("rc=$((rc | 2))\n");
        }
    }
    try w.writeAll("exit $rc\n");
}

/// The parts that failed, from the setup connection's exit status. ssh
/// reports its own failures as 255; any status outside the script's
/// bitmask (a missing `/bin/sh`, a signal) means the script did not finish.
fn setupFailures(term: std.process.Child.Term, wanted: SetupParts) SetupParts {
    const rc = switch (term) {
        .exited => |rc| rc,
        else => return wanted,
    };
    if (rc > 3) return wanted;
    return .{
        .terminfo = wanted.terminfo and rc & 1 != 0,
        .integration = wanted.integration and rc & 2 != 0,
    };
}

/// Run the one-time remote setup for the `wanted` parts over a single
/// short-lived SSH ControlMaster connection and return the parts that
/// failed. The master tears down with the client (`ControlPersist=no`) so
/// no socket lingers.
fn runRemoteSetup(
    alloc: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
    wanted: SetupParts,
    integration_version: []const u8,
) SetupParts {
    const script = script: {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        if (wanted.terminfo) terminfopkg.ghostty.encode(&buf.writer) catch |err| {
            log.warn("terminfo encode failed: {}", .{err});
            return wanted;
        };
        break :script remoteSetupScript(
            alloc,
            wanted,
            buf.written(),
            &integration_files,
            integration_version,
            opts.verbose,
        ) catch return wanted;
    };

    // ControlPath is a Unix domain socket; macOS sockaddr_un.sun_path is
    // 104 bytes including NUL, and OpenSSH may append a connection hash.
    const control_path = allocControlSocketPath(alloc) catch return wanted;
    const control_path_opt = std.fmt.allocPrint(
        alloc,
        "ControlPath={s}",
        .{control_path},
    ) catch return wanted;

    // Set up an SSH ControlMaster scoped to this single setup:
    //   - ControlMaster=yes makes our client also act as the master.
    //   - ControlPersist=no tears the master down when our client
    //     exits; no socket lingers on the remote side.
    const argv = std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        &.{
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", control_path_opt,
        },
        opts._ssh_args.items,
        &.{"/bin/sh -s"},
    }) catch return wanted;
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});

    // Under --verbose, inherit ssh's stderr so remote errors reach the
    // user's terminal.
    var child = std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = if (opts.verbose) .inherit else .ignore,
    }) catch |err| {
        log.warn("remote setup spawn failed: {}", .{err});
        return wanted;
    };

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(global.io(), script) catch {};
        stdin.close(global.io());
        child.stdin = null;
    }

    const term = child.wait(global.io()) catch |err| {
        log.warn("remote setup wait failed: {}", .{err});
        return wanted;
    };
    const failed = setupFailures(term, wanted);
    if (failed.any()) log.warn("remote setup failed: {}", .{term});
    return failed;
}

fn controlOpts(alloc: Allocator, mux: ssh_mux.Session) ![]const []const u8 {
    const path_opt = try std.fmt.allocPrint(alloc, "ControlPath={s}", .{mux.control_path});
    // The option list must be owned by `alloc`: an anonymous array literal
    // containing `path_opt` would be stack-allocated in this frame, and the
    // returned pointer would dangle the moment we return.
    return switch (mux.role) {
        .client => try std.mem.concat(alloc, []const u8, &.{
            &.{ "-o", "ControlMaster=auto" },
            &.{ "-o", path_opt },
        }),
        .master => try std.mem.concat(alloc, []const u8, &.{
            &.{ "-o", "ControlMaster=auto", "-o", "ControlPersist=yes" },
            &.{ "-o", path_opt },
        }),
        .legacy => try std.mem.concat(alloc, []const u8, &.{
            &.{ "-o", "ControlMaster=yes", "-o", "ControlPersist=no" },
            &.{ "-o", path_opt },
        }),
    };
}

fn waitForMaster(
    alloc: Allocator,
    ssh: []const u8,
    control_path: []const u8,
    destination: []const u8,
    timeout_ms: u32,
) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) {
        if (checkMaster(alloc, ssh, control_path, destination)) return true;
        std.Io.sleep(global.io(), .fromMilliseconds(100), .awake) catch return false;
        waited += 100;
    }
    return false;
}

fn prepareMux(
    alloc: Allocator,
    ssh: []const u8,
    dest: []const u8,
    key: ?[]const u8,
) !ssh_mux.Session {
    const key_val = key orelse {
        return .{
            .control_path = try allocControlSocketPath(alloc),
            .destination = dest,
            .key = null,
            .role = .legacy,
            .lock_dir = null,
        };
    };
    const sock = try ssh_mux.sockPath(alloc, key_val);
    if (checkMaster(alloc, ssh, sock, dest)) {
        return .{ .control_path = sock, .destination = dest, .key = key_val, .role = .client, .lock_dir = null };
    }
    std.Io.Dir.deleteFileAbsolute(global.io(), sock) catch {};

    if (try ssh_mux.tryLock(alloc, key_val)) |lock| {
        if (checkMaster(alloc, ssh, sock, dest)) {
            ssh_mux.unlock(lock);
            alloc.free(lock);
            return .{ .control_path = sock, .destination = dest, .key = key_val, .role = .client, .lock_dir = null };
        }
        ssh_mux.writeInfo(alloc, key_val, ssh, dest);
        return .{ .control_path = sock, .destination = dest, .key = key_val, .role = .master, .lock_dir = lock };
    }

    if (waitForMaster(alloc, ssh, sock, dest, 15_000)) {
        return .{ .control_path = sock, .destination = dest, .key = key_val, .role = .client, .lock_dir = null };
    }
    log.warn("shared master unavailable; falling back to per-session socket", .{});
    return .{
        .control_path = try allocControlSocketPath(alloc),
        .destination = dest,
        .key = null,
        .role = .legacy,
        .lock_dir = null,
    };
}

/// Run the user's interactive SSH process while publishing its multiplexing
/// socket for uploads and, when enabled, monitoring remote listening ports.
fn runInteractiveSession(
    gpa: Allocator,
    opts: *const Options,
    argv: []const []const u8,
    mux: ?ssh_mux.Session,
) !u8 {
    var child = try std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const auto_forward = opts.@"auto-forward" and envFlagEnabled(
        "GHOSTTY_SSH_AUTO_FORWARD",
    );
    const forward_notify = opts.@"forward-notify" and envFlagEnabled(
        "GHOSTTY_SSH_AUTO_FORWARD_NOTIFY",
    );

    const pid = ssh_session.currentPid();
    const ledger_path: ?[]const u8 = if (mux) |m| (if (m.key) |key|
        ssh_mux.tunnelsPath(gpa, key) catch null
    else
        ssh_session.tunnelsPathForPid(gpa, pid) catch null) else null;
    if (mux) |m| {
        ssh_session.write(gpa, pid, .{
            .control_path = m.control_path,
            .destination = m.destination,
            .ssh = opts.ssh,
            .key = m.key,
        }) catch |err| log.warn("unable to publish SSH session: {t}", .{err});
    }
    ssh_session.sweepStale(gpa);
    if (mux) |m| if (ledger_path) |lp| pruneStaleForwards(gpa, opts.ssh, m.control_path, m.destination, lp);
    var watch_pid = std.atomic.Value(i32).init(0);
    var running = std.atomic.Value(bool).init(true);
    const monitor = if (mux) |m| blk: {
        const lp = ledger_path orelse break :blk null;
        break :blk std.Thread.spawn(.{}, monitorRemotePorts, .{
            MonitorArgs{
                .ssh = opts.ssh,
                .control_path = m.control_path,
                .destination = m.destination,
                .notify = forward_notify,
                .ledger_path = lp,
                .key = m.key,
                .lock_dir = m.lock_dir,
                .auto_forward = auto_forward,
                .pid = pid,
                .running = &running,
                .watch_pid = &watch_pid,
            },
        }) catch null;
    } else null;
    if (monitor == null) {
        if (mux) |m| if (m.lock_dir) |lock| ssh_mux.unlock(lock);
    }
    defer {
        running.store(false, .release);
        const wpid = watch_pid.swap(0, .acq_rel);
        if (wpid > 0 and builtin.os.tag != .windows) {
            std.posix.kill(@intCast(wpid), std.posix.SIG.TERM) catch {};
        }
        if (monitor) |thread| thread.join();
        ssh_session.remove(gpa, pid);
        if (mux) |m| {
            if (m.key) |key| {
                if (!ssh_session.anyWithKey(gpa, key)) {
                    _ = std.process.run(gpa, global.io(), .{
                        .argv = &.{ opts.ssh, "-S", m.control_path, "-O", "exit", m.destination },
                    }) catch {};
                    ssh_mux.unlinkMuxFiles(gpa, key, m.control_path);
                }
            }
        }
    }

    const term = try child.wait(global.io());
    return exitCode(term);
}

fn envFlagEnabled(name: []const u8) bool {
    var environ = global.environMap() catch return true;
    defer environ.deinit();
    return !std.mem.eql(u8, environ.get(name) orelse return true, "0");
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@intFromEnum(sig), 127))),
        .stopped, .unknown => 1,
    };
}
/// One pass of remote listening-port discovery. Emits one candidate port per
/// line, deduplicated by the caller. A port is a candidate when either:
///
///   * the owning process is interactive — its fd 0 is a TTY — so the
///     listener was started from some user shell on the host (any bind
///     address). This is the cmux-style TTY attribution, and it catches dev
///     servers bound to a specific interface.
///
///   * or the listener is on loopback / all-interfaces and unprivileged,
///     which keeps covering daemonized dev services with no TTY such as
///     docker-proxy.
///
/// Toolchain: `ss -ltnp` + `readlink /proc/<pid>/fd/0` on Linux, `ps` +
/// `lsof -Fpn` on BSD/macOS, `netstat` as an address-only last resort.
/// Nothing is installed on the remote host; everything runs over the
/// existing session channel. The infra denylist (`isIgnoredPort`) is applied
/// by the local caller, not here.
const port_scan_script =
    \\if command -v ss >/dev/null 2>&1 && [ -d /proc ]; then
    \\  ss -ltnp 2>/dev/null | awk '
    \\    $1 ~ /^(State|Netid)$/ { next }
    \\    {
    \\      line = $0
    \\      addr = $4
    \\      pids = ""
    \\      while (match(line, /pid=[0-9]+/)) {
    \\        pids = pids " " substr(line, RSTART + 4, RLENGTH - 4)
    \\        line = substr(line, RSTART + RLENGTH)
    \\      }
    \\      print addr pids
    \\    }
    \\  ' | while read -r addr pids; do
    \\    port=${addr##*:}
    \\    case $port in ''|*[!0-9]*) continue ;; esac
    \\    [ "$port" -ge 1024 ] || continue
    \\    for pid in $pids; do
    \\      scan_tty=$(readlink "/proc/$pid/fd/0" 2>/dev/null)
    \\      case $scan_tty in
    \\        /dev/pts/*|/dev/tty*) printf '%s\n' "$port"; continue 2 ;;
    \\      esac
    \\    done
    \\    case $addr in
    \\      127.0.0.1:*|localhost:*|0.0.0.0:*|\*:*) printf '%s\n' "$port" ;;
    \\      \[::\]:*|\[::1\]:*) printf '%s\n' "$port" ;;
    \\    esac
    \\  done
    \\elif command -v lsof >/dev/null 2>&1; then
    \\  scan_ps=$(ps -axo pid=,tty= 2>/dev/null)
    \\  scan_ls=$(lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null)
    \\  printf '%s\n%s\n' "$scan_ps" "$scan_ls" | awk '
    \\    $1 ~ /^[0-9]+$/ && NF == 2 {
    \\      if ($2 != "?" && $2 != "??" && $2 != "-") tty[$1] = $2
    \\      next
    \\    }
    \\    /^p[0-9]+$/ { cur = tty[substr($0, 2)]; next }
    \\    /^n/ {
    \\      name = substr($0, 2)
    \\      sub(/->.*/, "", name)
    \\      port = name
    \\      sub(/^.*:/, "", port)
    \\      if (port !~ /^[0-9]+$/) next
    \\      if (port + 0 < 1024) next
    \\      if (cur != "") { print port; next }
    \\      host = name
    \\      sub(/:[0-9]+$/, "", host)
    \\      if (host == "*" || host == "localhost" || host == "127.0.0.1" ||
    \\          host == "0.0.0.0" || host == "[::]" || host == "[::1]" ||
    \\          host == "::" || host == "::1") print port
    \\    }
    \\  '
    \\elif command -v netstat >/dev/null 2>&1; then
    \\  {
    \\    netstat -lnt 2>/dev/null
    \\    netstat -an -p tcp 2>/dev/null
    \\  } | awk '
    \\    /LISTEN/ {
    \\      addr = $4
    \\      port = addr
    \\      sub(/^.*[.:]/, "", port)
    \\      if (port !~ /^[0-9]+$/) next
    \\      if (port + 0 < 1024) next
    \\      host = addr
    \\      sub(/[.:][0-9]+$/, "", host)
    \\      if (host == "*" || host == "" || host == "localhost" ||
    \\          host == "127.0.0.1" || host == "0.0.0.0" || host == "::" ||
    \\          host == "::1") print port
    \\    }
    \\  '
    \\fi
;

const port_watch_head =
    \\old=${TMPDIR:-/tmp}/niftty-ports-$$
    \\: > "$old"
    \\trap 'rm -f "$old" "$old.new"' EXIT
    \\while :; do
    \\  {
    \\
;

const port_watch_tail =
    \\
    \\  } | sort -u > "$old.new"
    \\  if ! [ -s "$old" ]; then
    \\    while IFS= read -r line; do
    \\      [ -n "$line" ] && printf 'P %s\n' "$line"
    \\    done < "$old.new"
    \\  else
    \\    while IFS= read -r line; do
    \\      [ -z "$line" ] && continue
    \\      grep -F -x -q "$line" "$old" || printf 'P %s\n' "$line"
    \\    done < "$old.new"
    \\    while IFS= read -r line; do
    \\      [ -z "$line" ] && continue
    \\      grep -F -x -q "$line" "$old.new" || printf 'R %s\n' "$line"
    \\    done < "$old"
    \\  fi
    \\  mv "$old.new" "$old"
    \\  sleep 2
    \\done
;

const port_watch_script = port_watch_head ++ port_scan_script ++ port_watch_tail;
/// The cwd reporter script before the login-shell `exec` line. Split so
/// `--cwd` can insert a `cd`, and `--shell-integration` a launcher, between
/// head and tail.
const cwd_reporter_head =
    \\exec /bin/sh -c 'trap "" INT TTOU TTIN
    \\set +m
    \\exec 9<&0
    \\(trap - INT TTOU TTIN;
;

/// The plain login-shell `exec` line of the cwd reporter.
const cwd_reporter_login =
    \\ exec "${SHELL:-/bin/sh}" -l 0<&9 1>&9 2>&9 9<&-
;

/// The cwd reporter script after the login-shell `exec` line. Split
/// around the pwd printf so `cwdReporterCommand` can swap in the tmux
/// passthrough form when `+ssh` itself runs inside tmux: the OSC 7 the
/// middleman writes would otherwise be dropped by the local tmux.
const cwd_reporter_watch_pre =
    \\) &
    \\spid=$!
    \\last=
    \\while :; do
    \\  if [ -r /proc/$spid/stat ]; then
    \\    state=$(sed -n "s/.*) \([^ ]\).*/\1/p" /proc/$spid/stat 2>/dev/null)
    \\    if [ -z "$state" ] || [ "$state" = Z ]; then break; fi
    \\  else
    \\    st=$(ps -o stat= -p $spid 2>/dev/null | tr -d " ")
    \\    case "$st" in ""|Z*) break ;; esac
    \\  fi
    \\  cwd=$(readlink /proc/$spid/cwd 2>/dev/null)
    \\  if [ -z "$cwd" ]; then
    \\    cwd=$(lsof -a -p $spid -d cwd -Fn 2>/dev/null | sed -n "s/^n//p" | head -n 1)
    \\  fi
    \\  case "$cwd" in
    \\    /*) ;;
    \\    *) cwd= ;;
    \\  esac
    \\  case "$cwd" in
    \\    /proc/[0-9]*/cwd*|*"(readlink:"*) cwd= ;;
    \\  esac
    \\  if [ "$cwd" != "$last" ]; then
;

/// The pwd report printf, plain form.
const cwd_reporter_pwd_printf =
    \\    printf "\033]7;kitty-shell-cwd://niftty-ssh%s\007" "$cwd"
;

/// The pwd report printf wrapped in tmux's DCS passthrough (every ESC
/// in the payload doubled). The local tmux forwards it and Niftty
/// decodes it.
const cwd_reporter_pwd_printf_tmux =
    \\    printf "\033Ptmux;\033\033]7;kitty-shell-cwd://niftty-ssh%s\007\033\\" "$cwd"
;

const cwd_reporter_watch_post =
    \\    last=$cwd
    \\  fi
    \\  sleep 1
    \\done
    \\wait $spid
    \\exit $?'
;

const cwd_reporter_watch =
    cwd_reporter_watch_pre ++ cwd_reporter_pwd_printf ++ cwd_reporter_watch_post;

/// Composed cwd reporter. See `cwdReporterCommand` for the `--cwd` and
/// shell integration variants.
const cwd_reporter_command = cwd_reporter_head ++ cwd_reporter_login ++ cwd_reporter_watch;

/// The remote command for interactive logins: the cwd reporter, with an
/// initial `cd` inserted before the login shell when `cwd` is an
/// absolute path. The `cd` is best-effort (a failed `cd` falls back to
/// the default directory). The path is escaped for the single-quoted
/// script since it survives two shell parse levels (the remote shell,
/// then the inner `/bin/sh -c`). A non-null `launcher` (see
/// `integrationLauncher`) replaces the plain login-shell `exec`.
/// `in_tmux` selects the tmux passthrough form of the pwd report for
/// when this `+ssh` itself runs inside a local tmux.
fn cwdReporterCommand(
    alloc: Allocator,
    cwd: ?[]const u8,
    launcher: ?[]const u8,
    in_tmux: bool,
) Allocator.Error![]const u8 {
    const login = launcher orelse cwd_reporter_login;
    const dir = cwd orelse "";
    const watch = if (in_tmux)
        cwd_reporter_watch_pre ++ cwd_reporter_pwd_printf_tmux ++ cwd_reporter_watch_post
    else
        cwd_reporter_watch;
    if (!std.mem.startsWith(u8, dir, "/")) {
        if (launcher == null and !in_tmux) return cwd_reporter_command;
        return std.mem.concat(alloc, u8, &.{ cwd_reporter_head, login, watch });
    }

    var escaped: std.ArrayList(u8) = .empty;
    for (dir) |c| {
        if (c == '\'') {
            try escaped.appendSlice(alloc, "'\\''");
        } else {
            try escaped.append(alloc, c);
        }
    }

    const cd = try std.fmt.allocPrint(
        alloc,
        "cd -- '{s}' 2>/dev/null;",
        .{escaped.items},
    );
    return std.mem.concat(alloc, u8, &.{ cwd_reporter_head, cd, login, watch });
}

/// Local `GHOSTTY_SHELL_FEATURES` entries forwarded to the remote shell
/// integration. The others need local binaries or `TERMINFO` (`path`,
/// `sudo`) or would wrap the remote `ssh` with a missing `niftty`.
const remote_shell_features = [_][]const u8{ "cursor", "cursor:blink", "cursor:steady", "title", "tmux" };

/// Append `value` keeping only characters that are inert inside the
/// cwd reporter's single-quoted script and its double-quoted launcher.
fn appendLauncherSafe(
    alloc: Allocator,
    list: *std.ArrayList(u8),
    value: []const u8,
) Allocator.Error!void {
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.', ':', ',', '+', '-' => try list.append(alloc, c),
        else => {},
    };
}

/// The login-shell launcher for `--shell-integration`: loads the remote
/// install of `version` into zsh (`ZDOTDIR`) or bash 4+ (`--posix` +
/// `ENV`) with the same environment contract as the local shell
/// integration, and otherwise (no complete install, bash 3 such as
/// Apple's `/bin/bash`, which ignores `ENV` in POSIX mode, other shells)
/// runs the plain login shell. Runs inside the cwd reporter's
/// single-quoted script, so it uses no single quotes and only inserts
/// `appendLauncherSafe` values. `prediction` and `features` are the
/// local `GHOSTTY_PREDICTION` and `GHOSTTY_SHELL_FEATURES` values.
/// `in_tmux` is set when this `+ssh` runs inside a local tmux: the
/// remote shell integration then wraps its marks in tmux's passthrough
/// (GHOSTTY_TMUX_PASSTHROUGH) so they survive the trip through the
/// local tmux. When the `tmux` feature is forwarded, the remote zsh
/// integration also gets its integration dir (GHOSTTY_SHELL_INTEGRATION_DIR)
/// so a `tmux` started on the remote host integrates its panes too.
fn integrationLauncher(
    alloc: Allocator,
    version: []const u8,
    prediction: ?[]const u8,
    features: []const u8,
    in_tmux: bool,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, " s=\"${SHELL:-/bin/sh}\"; d=\"" ++ integration_remote_root ++ "/");
    try appendLauncherSafe(alloc, &out, version);
    try out.appendSlice(alloc, "\"\nif [ -r \"$d/ok\" ]; then\nexport GHOSTTY_PREDICTION=");
    const enabled = if (prediction) |p| std.mem.eql(u8, p, "1") else false;
    try out.append(alloc, if (enabled) '1' else '0');

    var forwarded: std.ArrayList(u8) = .empty;
    var tmux_feature = false;
    var it = std.mem.splitScalar(u8, features, ',');
    while (it.next()) |feature| {
        for (remote_shell_features) |allowed| {
            if (!std.mem.eql(u8, feature, allowed)) continue;
            if (std.mem.eql(u8, feature, "tmux")) tmux_feature = true;
            if (forwarded.items.len > 0) try forwarded.append(alloc, ',');
            try appendLauncherSafe(alloc, &forwarded, feature);
            break;
        }
    }
    if (in_tmux) {
        try out.appendSlice(alloc, " GHOSTTY_TMUX_PASSTHROUGH=1");
    }
    if (tmux_feature) {
        try out.appendSlice(alloc, " GHOSTTY_SHELL_INTEGRATION_DIR=\"$d/zsh\"");
    }
    if (forwarded.items.len > 0) {
        try out.appendSlice(alloc, " GHOSTTY_SHELL_FEATURES=");
        try out.appendSlice(alloc, forwarded.items);
    }

    try out.appendSlice(alloc,
        \\
        \\case "${s##*/}" in
        \\zsh) if [ -n "${ZDOTDIR+x}" ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; fi
        \\export ZDOTDIR="$d/zsh"; exec "$s" -l 0<&9 1>&9 2>&9 9<&- ;;
        \\bash) case "$("$s" -c "echo \${BASH_VERSINFO[0]}" 2>/dev/null)" in
        \\[4-9]|[1-9][0-9]) if [ -n "${ENV+x}" ]; then export GHOSTTY_BASH_ENV="$ENV"; fi
        \\export ENV="$d/bash/ghostty.bash" GHOSTTY_BASH_INJECT=1
        \\if [ -z "${HISTFILE+x}" ]; then export HISTFILE="$HOME/.bash_history" GHOSTTY_BASH_UNEXPORT_HISTFILE=1; fi
        \\exec "$s" --posix -l 0<&9 1>&9 2>&9 9<&- ;;
        \\esac ;;
        \\esac
        \\fi
        \\exec "$s" -l 0<&9 1>&9 2>&9 9<&-
    );
    return out.items;
}

/// A copy of the local environment variable `name`, or null when unset.
fn localEnv(alloc: Allocator, name: []const u8) ?[]const u8 {
    var environ = global.environMap() catch return null;
    defer environ.deinit();
    const value = environ.get(name) orelse return null;
    return alloc.dupe(u8, value) catch null;
}

fn sshFlagTakesArg(flag: u8) bool {
    return switch (flag) {
        'B',
        'b',
        'c',
        'D',
        'E',
        'e',
        'F',
        'I',
        'i',
        'J',
        'L',
        'l',
        'm',
        'O',
        'o',
        'p',
        'P',
        'Q',
        'R',
        'S',
        'W',
        'w',
        => true,
        else => false,
    };
}

fn requestTtyDisabled(value: []const u8) bool {
    const prefix = "RequestTTY";
    if (value.len < prefix.len or !std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) {
        return false;
    }
    const rest = std.mem.trim(u8, value[prefix.len..], " \t=");
    return std.ascii.eqlIgnoreCase(rest, "no");
}

/// True when `+ssh` should wrap the remote login with the cwd reporter.
/// Interactive logins only: a remote command, `-N`/`-W`, or `-T` skip it.
fn shouldInjectCwdReporter(args: []const []const u8) bool {
    var i: usize = 0;
    var disable_tty = false;
    var no_shell = false;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;

        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const c = arg[j];
            switch (c) {
                'N' => no_shell = true,
                'T' => disable_tty = true,
                'W' => no_shell = true,
                else => {},
            }
            if (!sshFlagTakesArg(c)) continue;
            const attached = arg[j + 1 ..];
            const value: []const u8 = if (attached.len > 0) attached else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            if (c == 'o' and requestTtyDisabled(value)) disable_tty = true;
            break;
        }
        i += 1;
    }
    if (i >= args.len or disable_tty or no_shell) return false;
    return i + 1 >= args.len;
}

test "shouldInjectCwdReporter: interactive login" {
    const testing = std.testing;
    try testing.expect(shouldInjectCwdReporter(&.{"user@example.com"}));
    try testing.expect(shouldInjectCwdReporter(&.{ "-p", "22", "user@example.com" }));
    try testing.expect(shouldInjectCwdReporter(&.{ "-p22", "user@example.com" }));
    try testing.expect(shouldInjectCwdReporter(&.{ "-vv", "user@example.com" }));
    try testing.expect(shouldInjectCwdReporter(&.{ "-J", "jump", "user@example.com" }));
    try testing.expect(shouldInjectCwdReporter(&.{ "-4t", "user@example.com" }));
    try testing.expect(shouldInjectCwdReporter(&.{ "--", "user@example.com" }));
}

test "shouldInjectCwdReporter: skip remote command and no-shell" {
    const testing = std.testing;
    try testing.expect(!shouldInjectCwdReporter(&.{ "user@example.com", "ls" }));
    try testing.expect(!shouldInjectCwdReporter(&.{ "--", "user@example.com", "ls" }));
    try testing.expect(!shouldInjectCwdReporter(&.{ "-N", "user@example.com" }));
    try testing.expect(!shouldInjectCwdReporter(&.{ "-T", "user@example.com" }));
    try testing.expect(!shouldInjectCwdReporter(&.{ "-W", "localhost:1234", "user@example.com" }));
    try testing.expect(!shouldInjectCwdReporter(&.{ "-o", "RequestTTY=no", "user@example.com" }));
    try testing.expect(!shouldInjectCwdReporter(&.{ "-oRequestTTY=no", "user@example.com" }));
    try testing.expect(!shouldInjectCwdReporter(&.{}));
}

test "cwd reporter watches child not parent" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, cwd_reporter_command, "/proc/$spid/cwd") != null);
    // The login shell must sit on the middleman's saved pty fd (9), never
    // on the /dev/tty device or a path resolved by an external command:
    // tmux 3.7+ rejects clients whose ttyname() is "/dev/tty", and a
    // `tty`-based resolution silently degraded to exactly that.
    try testing.expect(std.mem.indexOf(u8, cwd_reporter_command, "exec 9<&0") != null);
    try testing.expect(std.mem.indexOf(u8, cwd_reporter_command, "0<&9 1>&9 2>&9 9<&-") != null);
    try testing.expect(std.mem.indexOf(u8, cwd_reporter_command, "/dev/tty") == null);
    try testing.expect(std.mem.indexOf(u8, cwd_reporter_command, "tt=") == null);
    try testing.expect(std.mem.indexOf(u8, cwd_reporter_command, "wait $spid") != null);
    try testing.expect(std.mem.indexOf(u8, cwd_reporter_command, "trap - INT TTOU TTIN") != null);
    try testing.expect(std.mem.indexOf(u8, cwd_reporter_command, "/proc/$PPID/cwd") == null);
}

test "cwdReporterCommand: --cwd inserts escaped cd before login shell" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cmd = try cwdReporterCommand(arena.allocator(), "/srv/o'brien app", null, false);
    try testing.expect(std.mem.indexOf(
        u8,
        cmd,
        "cd -- '/srv/o'\\''brien app' 2>/dev/null; exec \"${SHELL:-/bin/sh}\" -l",
    ) != null);

    // Non-absolute or absent cwd leaves the plain reporter untouched.
    try testing.expectEqualStrings(
        cwd_reporter_command,
        try cwdReporterCommand(arena.allocator(), "relative", null, false),
    );
    try testing.expectEqualStrings(
        cwd_reporter_command,
        try cwdReporterCommand(arena.allocator(), null, null, false),
    );
}

test "cwdReporterCommand: plain login exec without shell integration" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cmd = try cwdReporterCommand(arena.allocator(), null, null, false);
    try testing.expect(std.mem.indexOf(
        u8,
        cmd,
        "(trap - INT TTOU TTIN; exec \"${SHELL:-/bin/sh}\" -l 0<&9 1>&9 2>&9 9<&-) &\nspid=$!\n",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "shell-integration") == null);
}

test "cwdReporterCommand: launcher replaces login exec after cd" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const launcher = try integrationLauncher(alloc, "0123456789abcdef", "1", "title", false);
    const cmd = try cwdReporterCommand(alloc, "/srv", launcher, false);
    const cd = "cd -- '/srv' 2>/dev/null; s=\"${SHELL:-/bin/sh}\"";
    try testing.expect(std.mem.indexOf(u8, cmd, cd) != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "exec \"${SHELL:-/bin/sh}\" -l") == null);
    try testing.expect(std.mem.endsWith(u8, cmd, cwd_reporter_watch));
    // The command is one single-quoted script: only the cd path may
    // contribute quotes, and the launcher itself has none.
    try testing.expect(std.mem.indexOfScalar(u8, launcher, '\'') == null);

    const no_cwd = try cwdReporterCommand(alloc, null, launcher, false);
    try testing.expect(std.mem.indexOf(u8, no_cwd, "(trap - INT TTOU TTIN; s=") != null);
}

test "integrationLauncher: zsh ZDOTDIR, bash --posix ENV, plain fallback" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const l = try integrationLauncher(arena.allocator(), "0123456789abcdef", "1", "cursor:blink,title", false);
    const dir = "d=\"$HOME/.local/share/niftty/shell-integration/0123456789abcdef\"";
    try testing.expect(std.mem.indexOf(u8, l, dir) != null);
    try testing.expect(std.mem.indexOf(u8, l, "if [ -r \"$d/ok\" ]; then\n") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        l,
        "export GHOSTTY_PREDICTION=1 GHOSTTY_SHELL_FEATURES=cursor:blink,title\n",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        l,
        "zsh) if [ -n \"${ZDOTDIR+x}\" ]; then export GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\"; fi\n" ++
            "export ZDOTDIR=\"$d/zsh\"; exec \"$s\" -l 0<&9 1>&9 2>&9 9<&- ;;",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        l,
        "export ENV=\"$d/bash/ghostty.bash\" GHOSTTY_BASH_INJECT=1\n",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        l,
        "export HISTFILE=\"$HOME/.bash_history\" GHOSTTY_BASH_UNEXPORT_HISTFILE=1",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, l, "exec \"$s\" --posix -l 0<&9 1>&9 2>&9 9<&- ;;") != null);
    // Only bash 4+ honors ENV in POSIX mode; older bash gets the plain login.
    try testing.expect(std.mem.indexOf(
        u8,
        l,
        "bash) case \"$(\"$s\" -c \"echo \\${BASH_VERSINFO[0]}\" 2>/dev/null)\" in\n[4-9]|[1-9][0-9]) ",
    ) != null);
    // Without a complete install, or for other shells, the plain login.
    try testing.expect(std.mem.endsWith(u8, l, "esac\nfi\nexec \"$s\" -l 0<&9 1>&9 2>&9 9<&-"));
}

test "integrationLauncher: only safe values and remote-capable features" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Local-only features are dropped; cursor/title survive.
    const filtered = try integrationLauncher(
        alloc,
        "v",
        null,
        "cursor:blink,path,ssh-env,ssh-integration,ssh-terminfo,sudo,title",
        false,
    );
    try testing.expect(std.mem.indexOf(
        u8,
        filtered,
        "export GHOSTTY_PREDICTION=0 GHOSTTY_SHELL_FEATURES=cursor:blink,title\n",
    ) != null);

    // Unsafe characters never reach the single-quoted script.
    const unsafe = try integrationLauncher(
        alloc,
        "ab'c$(x)d",
        "1'; rm -rf /",
        "title'$(x),ti tle,`id`,sudo",
        false,
    );
    try testing.expect(std.mem.indexOf(u8, unsafe, "shell-integration/abcxd\"") != null);
    try testing.expect(std.mem.indexOf(u8, unsafe, "export GHOSTTY_PREDICTION=0\n") != null);
    try testing.expect(std.mem.indexOf(u8, unsafe, "GHOSTTY_SHELL_FEATURES") == null);
    try testing.expect(std.mem.indexOfAny(u8, unsafe, "'`") == null);
}

test "integrationLauncher: tmux passthrough exports" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Both: +ssh inside a local tmux with the tmux feature forwarded.
    const both = try integrationLauncher(alloc, "0123456789abcdef", "1", "cursor,tmux", true);
    try testing.expect(std.mem.indexOf(
        u8,
        both,
        " GHOSTTY_TMUX_PASSTHROUGH=1 GHOSTTY_SHELL_INTEGRATION_DIR=\"$d/zsh\"",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, both, "export GHOSTTY_PREDICTION=1") != null);

    // Feature alone: no local tmux, but a tmux on the remote host still
    // gets pane integration through the exported integration dir.
    const feature_only = try integrationLauncher(alloc, "0123456789abcdef", "1", "cursor,tmux", false);
    try testing.expect(std.mem.indexOf(
        u8,
        feature_only,
        "GHOSTTY_SHELL_INTEGRATION_DIR=\"$d/zsh\"",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, feature_only, "GHOSTTY_TMUX_PASSTHROUGH") == null);

    // Local tmux alone: feature off, so nothing the integration would use.
    const tmux_only = try integrationLauncher(alloc, "0123456789abcdef", "1", "cursor", true);
    try testing.expect(std.mem.indexOf(u8, tmux_only, "GHOSTTY_TMUX_PASSTHROUGH=1") != null);
    try testing.expect(std.mem.indexOf(u8, tmux_only, "GHOSTTY_SHELL_INTEGRATION_DIR") == null);

    // Neither: the remote env is unchanged.
    const plain = try integrationLauncher(alloc, "0123456789abcdef", "1", "cursor", false);
    try testing.expect(std.mem.indexOf(u8, plain, "GHOSTTY_TMUX_PASSTHROUGH") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "GHOSTTY_SHELL_INTEGRATION_DIR") == null);
}

test "cwdReporterCommand: tmux passthrough pwd printf" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmd = try cwdReporterCommand(alloc, null, null, true);
    try testing.expect(std.mem.indexOf(
        u8,
        cmd,
        "printf \"\\033Ptmux;\\033\\033]7;kitty-shell-cwd://niftty-ssh%s\\007\\033\\\\\" \"$cwd\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        cmd,
        "printf \"\\033]7;kitty-shell-cwd://niftty-ssh%s\\007\" \"$cwd\"",
    ) == null);
}

test "remoteSetupScript: installs every payload file and ends with exit $rc" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const version = integrationVersion(&integration_files);
    const script = try remoteSetupScript(
        alloc,
        .{ .terminfo = true, .integration = true },
        "xterm-ghostty|test,\n",
        &integration_files,
        &version,
        false,
    );
    try testing.expect(std.mem.startsWith(u8, script, "rc=0\n"));
    try testing.expect(std.mem.endsWith(u8, script, "exit $rc\n"));
    try testing.expect(std.mem.indexOf(u8, script, "tic -x - 2>/dev/null <<'" ++ setup_heredoc_delim ++ "'\n" ++
        "xterm-ghostty|test,\n" ++ setup_heredoc_delim ++ "\n") != null);

    const dir = try std.fmt.allocPrint(
        alloc,
        "d=\"$HOME/.local/share/niftty/shell-integration/{s}\"\n",
        .{&version},
    );
    try testing.expect(std.mem.indexOf(u8, script, dir) != null);
    for (integration_files) |file| {
        const heredoc = try std.fmt.allocPrint(
            alloc,
            "cat >\"$d/{s}\" 2>/dev/null <<'{s}' || si=1\n{s}{s}\n",
            .{ file.path, setup_heredoc_delim, file.contents, setup_heredoc_delim },
        );
        try testing.expect(std.mem.indexOf(u8, script, heredoc) != null);
    }
    // The ok marker comes after the last file.
    const ok = std.mem.indexOf(u8, script, "touch \"$d/ok\"").?;
    const last = std.mem.lastIndexOf(u8, script, "cat >\"$d/").?;
    try testing.expect(ok > last);

    // Only the wanted parts are emitted.
    const terminfo_only = try remoteSetupScript(alloc, .{ .terminfo = true }, "t\n", &integration_files, &version, false);
    try testing.expect(std.mem.indexOf(u8, terminfo_only, "shell-integration") == null);
    const integration_only = try remoteSetupScript(alloc, .{ .integration = true }, "", &integration_files, &version, false);
    try testing.expect(std.mem.indexOf(u8, integration_only, "tic -x") == null);
}

test "remoteSetupScript: payload containing the delimiter fails its part" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const files = [_]IntegrationFile{
        .{ .path = "zsh/.zshenv", .contents = "echo ok\n" },
        .{ .path = "bash/ghostty.bash", .contents = "a\n" ++ setup_heredoc_delim ++ "\nrm -rf ~\n" },
    };
    const script = try remoteSetupScript(
        alloc,
        .{ .terminfo = true, .integration = true },
        "terminfo\n",
        &files,
        "v",
        false,
    );
    try testing.expect(std.mem.indexOf(u8, script, "rm -rf") == null);
    try testing.expect(std.mem.indexOf(u8, script, "cat >") == null);
    try testing.expect(std.mem.indexOf(u8, script, "\nrc=$((rc | 2))\nexit $rc\n") != null);
    // The terminfo part is unaffected.
    try testing.expect(std.mem.indexOf(u8, script, "tic -x -") != null);

    // The delimiter as the last line without a newline is caught too.
    try testing.expect(!heredocSafe("x\n" ++ setup_heredoc_delim));
    try testing.expect(heredocSafe("x " ++ setup_heredoc_delim ++ "\n"));
}

test "setupFailures: exit status bitmask" {
    const testing = std.testing;
    const both: SetupParts = .{ .terminfo = true, .integration = true };
    try testing.expectEqual(SetupParts{}, setupFailures(.{ .exited = 0 }, both));
    try testing.expectEqual(SetupParts{ .terminfo = true }, setupFailures(.{ .exited = 1 }, both));
    try testing.expectEqual(SetupParts{ .integration = true }, setupFailures(.{ .exited = 2 }, both));
    try testing.expectEqual(both, setupFailures(.{ .exited = 3 }, both));
    // ssh's own failure, or a status the script never produces.
    try testing.expectEqual(both, setupFailures(.{ .exited = 255 }, both));
    try testing.expectEqual(both, setupFailures(.{ .exited = 127 }, both));
    // Unrequested parts never count as failed.
    try testing.expectEqual(SetupParts{}, setupFailures(.{ .exited = 1 }, .{ .integration = true }));
}

test "cacheVersion: composes terminfo and shell integration versions" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("t1", try cacheVersion(alloc, .{ .terminfo = true }, "t1", "h"));
    try testing.expectEqualStrings("si-h", try cacheVersion(alloc, .{ .integration = true }, "t1", "h"));
    try testing.expectEqualStrings("t1+si-h", try cacheVersion(
        alloc,
        .{ .terminfo = true, .integration = true },
        "t1",
        "h",
    ));

    // The composed version is a valid cache entry version and round-trips.
    const entry = @import("ssh_cache.zig").Entry.parse("host|1|t1+si-h").?;
    try testing.expectEqualStrings("t1+si-h", entry.terminfo_version);
}

test "integrationVersion: 16 hex chars tracking path and contents" {
    const testing = std.testing;
    const a = integrationVersion(&.{.{ .path = "zsh/a", .contents = "x" }});
    for (a) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    const b = integrationVersion(&.{.{ .path = "zsh/b", .contents = "x" }});
    const c = integrationVersion(&.{.{ .path = "zsh/a", .contents = "y" }});
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expect(!std.mem.eql(u8, &a, &c));
}

test "port watch script reports both additions and removals" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, port_watch_script, "'P %s\\n'") != null);
    try testing.expect(std.mem.indexOf(u8, port_watch_script, "'R %s\\n'") != null);
}

const MonitorArgs = struct {
    ssh: []const u8,
    control_path: []const u8,
    destination: []const u8,
    notify: bool,
    ledger_path: []const u8,
    key: ?[]const u8,
    lock_dir: ?[]const u8,
    auto_forward: bool,
    pid: u64,
    running: *std.atomic.Value(bool),
    watch_pid: *std.atomic.Value(i32),
};

fn sleepWhileRunning(running: *std.atomic.Value(bool), total_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < total_ms) {
        if (!running.load(.acquire)) return false;
        std.Io.sleep(global.io(), .fromMilliseconds(100), .awake) catch return false;
        waited += 100;
    }
    return running.load(.acquire);
}

fn monitorRemotePorts(args: MonitorArgs) void {
    const alloc = std.heap.page_allocator;

    while (args.running.load(.acquire)) {
        if (checkMaster(alloc, args.ssh, args.control_path, args.destination)) break;
        std.Io.sleep(global.io(), .fromMilliseconds(100), .awake) catch return;
    }
    if (args.lock_dir) |lock| ssh_mux.unlock(lock);
    if (!args.running.load(.acquire)) return;

    if (args.key == null) {
        if (args.auto_forward) pollLegacy(args, alloc) else maintainSessionFile(args, alloc);
        return;
    }

    while (args.running.load(.acquire)) {
        republishSession(args, alloc);
        if (!args.auto_forward) {
            if (!sleepWhileRunning(args.running, 2000)) return;
            continue;
        }
        if (!ssh_mux.tryClaimWatch(alloc, args.key.?, args.pid)) {
            if (!sleepWhileRunning(args.running, 5000)) return;
            continue;
        }
        pruneIgnoredPorts(args, alloc);
        runWatcher(args, alloc);
        if (!args.running.load(.acquire)) return;
        if (!checkMaster(alloc, args.ssh, args.control_path, args.destination)) return;
        if (!sleepWhileRunning(args.running, 1000)) return;
    }
}

/// Re-assert `ssh-sessions/<pid>`. The Ports panel and `+ssh-forward`
/// resolve everything through that file, so if anything removes it
/// mid-session (exit cleanup of an overlapping session, a stale sweep)
/// they report no session even while the forwards are alive and working.
fn republishSession(args: MonitorArgs, alloc: Allocator) void {
    ssh_session.write(alloc, args.pid, .{
        .control_path = args.control_path,
        .destination = args.destination,
        .ssh = args.ssh,
        .key = args.key,
    }) catch |err| log.warn("unable to publish SSH session: {t}", .{err});
}

/// With auto-forward disabled there is nothing to watch, but the Ports
/// panel still needs the session file to list and add tunnels manually.
fn maintainSessionFile(args: MonitorArgs, alloc: Allocator) void {
    while (args.running.load(.acquire)) {
        republishSession(args, alloc);
        if (!sleepWhileRunning(args.running, 2000)) return;
    }
}

fn pollLegacy(args: MonitorArgs, alloc: Allocator) void {
    pruneIgnoredPorts(args, alloc);
    while (args.running.load(.acquire)) {
        republishSession(args, alloc);
        const ports = discoverPorts(alloc, args.ssh, args.control_path, args.destination) catch {
            std.Io.sleep(global.io(), .fromMilliseconds(250), .awake) catch return;
            continue;
        };
        defer if (ports.len > 0) alloc.free(ports);
        for (ports) |remote_port| applyForward(args, alloc, remote_port);
        std.Io.sleep(global.io(), .fromMilliseconds(750), .awake) catch return;
    }
}

/// Clear `ignored` ledger entries for remote ports that are no longer
/// listening. Closing a tunnel from the Ports panel is a deliberate act
/// against a live server, so a port that is still up stays ignored; once its
/// listener is gone the port becomes eligible again and a restarted dev
/// server is re-forwarded instead of being silently banned forever.
fn pruneIgnoredPorts(args: MonitorArgs, alloc: Allocator) void {
    var ledger = ssh_tunnel.load(alloc, args.ledger_path) catch return;
    defer ledger.deinit();
    if (ledger.ignored.items.len == 0) return;

    const ports = discoverPorts(alloc, args.ssh, args.control_path, args.destination) catch return;
    defer if (ports.len > 0) alloc.free(ports);
    var dropped = false;
    var i = ledger.ignored.items.len;
    while (i > 0) {
        i -= 1;
        const port = ledger.ignored.items[i];
        if (std.mem.indexOfScalar(u16, ports, port) == null)
            dropped = ledger.dropIgnored(port) or dropped;
    }
    if (dropped) ssh_tunnel.save(alloc, args.ledger_path, ledger) catch {};
}

fn runWatcher(args: MonitorArgs, alloc: Allocator) void {
    var child = std.process.spawn(global.io(), .{
        .argv = &.{ args.ssh, "-S", args.control_path, args.destination, "sh", "-s" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return;
    if (child.id) |id| args.watch_pid.store(@intCast(id), .release);
    defer {
        args.watch_pid.store(0, .release);
        if (child.id != null) child.kill(global.io());
    }

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(global.io(), port_watch_script) catch {};
        stdin.close(global.io());
        child.stdin = null;
    }
    const stdout = child.stdout orelse return;
    var buf: [4096]u8 = undefined;
    var file_reader = stdout.reader(global.io(), &buf);
    const reader = &file_reader.interface;
    while (args.running.load(.acquire)) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => break,
            error.StreamTooLong => {
                _ = reader.take(buf.len) catch {};
                continue;
            },
        };
        switch (parseWatchEvent(line) orelse continue) {
            .add => |port| applyForward(args, alloc, port),
            .remove => |port| removeForward(args, alloc, port),
        }
    }
}

fn applyForward(args: MonitorArgs, alloc: Allocator, remote_port: u16) void {
    var ledger = ssh_tunnel.load(alloc, args.ledger_path) catch ssh_tunnel.Ledger{ .alloc = alloc };
    defer ledger.deinit();
    if (ledger.hasRemote(remote_port) or ledger.ignores(remote_port)) return;
    if (ledger.tunnels.items.len >= ssh_tunnel.max_auto_forwards) return;
    const local_port = ssh_tunnel.openLocal(
        alloc,
        args.ssh,
        args.control_path,
        args.destination,
        remote_port,
        null,
    ) catch return;
    ledger.add(
        ssh_tunnel.loopback,
        local_port,
        ssh_tunnel.loopback,
        remote_port,
    ) catch {
        _ = ssh_tunnel.closeLocal(
            alloc,
            args.ssh,
            args.control_path,
            args.destination,
            local_port,
            remote_port,
        ) catch {};
        return;
    };
    ssh_tunnel.save(alloc, args.ledger_path, ledger) catch {
        _ = ssh_tunnel.closeLocal(
            alloc,
            args.ssh,
            args.control_path,
            args.destination,
            local_port,
            remote_port,
        ) catch {};
        return;
    };
    if (args.notify) notifyForward(remote_port, local_port);
}

/// Close and forget a forward whose remote listener disappeared. Unlike
/// `Ledger.remove`, this deliberately does not mark the remote port
/// ignored: if the remote service restarts, auto-forward re-opens it.
fn removeForward(args: MonitorArgs, alloc: Allocator, remote_port: u16) void {
    var ledger = ssh_tunnel.load(alloc, args.ledger_path) catch return;
    defer ledger.deinit();
    const tunnel = for (ledger.tunnels.items) |tunnel| {
        if (tunnel.remote_port == remote_port) break tunnel;
    } else return;
    _ = ssh_tunnel.closeLocal(
        alloc,
        args.ssh,
        args.control_path,
        args.destination,
        tunnel.local_port,
        remote_port,
    ) catch {};
    _ = ledger.dropRemote(remote_port);
    ssh_tunnel.save(alloc, args.ledger_path, ledger) catch return;
}

/// Drop ledger entries that no longer reflect reality: when the master is
/// gone everything goes, otherwise only tunnels whose local listener died.
/// Never marks remotes ignored so auto-forward can re-open them later.
fn pruneStaleForwards(
    gpa: Allocator,
    ssh: []const u8,
    control_path: []const u8,
    destination: []const u8,
    ledger_path: []const u8,
) void {
    var ledger = ssh_tunnel.load(gpa, ledger_path) catch |err| {
        log.warn("unable to load tunnel ledger: {t}", .{err});
        return;
    };
    defer ledger.deinit();
    if (ledger.tunnels.items.len == 0) return;

    // Snapshot before mutating: dropRemote edits the list while iterating.
    const remote_ports = gpa.alloc(u16, ledger.tunnels.items.len) catch return;
    defer gpa.free(remote_ports);
    const local_ports = gpa.alloc(u16, ledger.tunnels.items.len) catch return;
    defer gpa.free(local_ports);
    for (ledger.tunnels.items, remote_ports, local_ports) |tunnel, *remote_port, *local_port| {
        remote_port.* = tunnel.remote_port;
        local_port.* = tunnel.local_port;
    }

    var dropped = false;
    if (!checkMaster(gpa, ssh, control_path, destination)) {
        for (remote_ports) |remote_port| dropped = ledger.dropRemote(remote_port) or dropped;
    } else {
        for (remote_ports, local_ports) |remote_port, local_port| {
            if (!ssh_tunnel.listenerAlive(local_port)) dropped = ledger.dropRemote(remote_port) or dropped;
        }
    }
    if (!dropped) return;
    ssh_tunnel.save(gpa, ledger_path, ledger) catch |err| {
        log.warn("unable to save tunnel ledger: {t}", .{err});
    };
}

const WatchEvent = union(enum) { add: u16, remove: u16 };

/// Watch lines are `P <port>` / `R <port>` with the port already filtered by
/// the remote scan (TTY-attributed or address-eligible, unprivileged range).
fn parseWatchEvent(raw: []const u8) ?WatchEvent {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var payload = trimmed;
    var removed = false;
    if (std.mem.startsWith(u8, payload, "R ")) {
        removed = true;
        payload = payload[2..];
    } else if (std.mem.startsWith(u8, payload, "P ")) {
        payload = payload[2..];
    }
    const port = std.fmt.parseUnsigned(u16, payload, 10) catch return null;
    if (!isForwardablePort(port) or isIgnoredPort(port)) return null;
    return if (removed) .{ .remove = port } else .{ .add = port };
}

fn checkMaster(
    alloc: Allocator,
    ssh: []const u8,
    control_path: []const u8,
    destination: []const u8,
) bool {
    const result = std.process.run(alloc, global.io(), .{
        .argv = &.{ ssh, "-S", control_path, "-O", "check", destination },
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return exitCode(result.term) == 0;
}

fn discoverPorts(
    alloc: Allocator,
    ssh: []const u8,
    control_path: []const u8,
    destination: []const u8,
) ![]u16 {
    const result = try std.process.run(alloc, global.io(), .{
        .argv = &.{ ssh, "-S", control_path, destination, port_scan_script },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (exitCode(result.term) != 0) return error.PortDiscoveryFailed;

    var ports: std.ArrayList(u16) = .empty;
    errdefer ports.deinit(alloc);
    var lines = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    while (lines.next()) |raw| {
        const port = std.fmt.parseUnsigned(u16, raw, 10) catch continue;
        if (!isForwardablePort(port) or isIgnoredPort(port)) continue;
        if (std.mem.indexOfScalar(u16, ports.items, port) == null) {
            try ports.append(alloc, port);
        }
    }
    return ports.toOwnedSlice(alloc);
}

fn isForwardablePort(port: u16) bool {
    return port >= 1024;
}

fn isIgnoredPort(port: u16) bool {
    return switch (port) {
        111, // rpcbind
        631, // cups
        873, // rsync
        2049, // nfs
        2375,
        2376,
        2377, // docker API / swarm
        3306, // mysql
        5353, // mdns
        5355, // llmnr
        5432, // postgres
        5672, // amqp
        6379, // redis
        6443, // kube-apiserver
        10250, // kubelet
        11211, // memcached
        27017, // mongodb
        => true,
        else => false,
    };
}

test "isForwardablePort: unprivileged including ephemeral" {
    const testing = std.testing;
    try testing.expect(!isForwardablePort(80));
    try testing.expect(!isForwardablePort(1023));
    try testing.expect(isForwardablePort(1024));
    try testing.expect(isForwardablePort(43210));
    try testing.expect(isForwardablePort(50000));
    try testing.expect(isForwardablePort(65535));
}

test "isIgnoredPort: infra skipped, web kept" {
    const testing = std.testing;
    try testing.expect(isIgnoredPort(5432));
    try testing.expect(isIgnoredPort(6379));
    try testing.expect(isIgnoredPort(3306));
    try testing.expect(!isIgnoredPort(3000));
    try testing.expect(!isIgnoredPort(8080));
    try testing.expect(!isIgnoredPort(5173));
}

test "parseWatchEvent: add and remove port events" {
    const testing = std.testing;
    try testing.expectEqual(WatchEvent{ .add = 3000 }, parseWatchEvent("P 3000"));
    try testing.expectEqual(WatchEvent{ .add = 43210 }, parseWatchEvent("P 43210\n"));
    try testing.expectEqual(WatchEvent{ .add = 8080 }, parseWatchEvent("8080"));
    try testing.expectEqual(WatchEvent{ .remove = 3000 }, parseWatchEvent("R 3000"));
    try testing.expectEqual(@as(?WatchEvent, null), parseWatchEvent("P 80"));
    try testing.expectEqual(@as(?WatchEvent, null), parseWatchEvent("P 5432"));
    try testing.expectEqual(@as(?WatchEvent, null), parseWatchEvent("P notaport"));
}

test "port scan script attributes listeners to tty owners" {
    const testing = std.testing;
    // Linux: ss process info + fd 0 readlink decides attribution.
    try testing.expect(std.mem.indexOf(u8, port_scan_script, "ss -ltnp") != null);
    try testing.expect(std.mem.indexOf(u8, port_scan_script, "readlink \"/proc/$pid/fd/0\"") != null);
    // BSD/macOS: ps tty map joined with lsof -Fpn output.
    try testing.expect(std.mem.indexOf(u8, port_scan_script, "ps -axo pid=,tty=") != null);
    try testing.expect(std.mem.indexOf(u8, port_scan_script, "lsof -nP -iTCP -sTCP:LISTEN -Fpn") != null);
    // Address-only fallback keeps covering daemonized listeners.
    try testing.expect(std.mem.indexOf(u8, port_scan_script, "netstat -an -p tcp") != null);
}

fn notifyForward(remote_port: u16, local_port: u16) void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print(
        "\x1b]777;notify;SSH port forwarded;Remote port {d} is available at 127.0.0.1:{d}\x1b\\",
        .{ remote_port, local_port },
    ) catch return;
    std.Io.File.stderr().writeStreamingAll(global.io(), writer.buffered()) catch {};
}

fn parseTestArgs(alloc: Allocator, opts: *Options, line: []const u8) !void {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(alloc, line);
    defer iter.deinit();
    try cli_args.parse(Options, alloc, opts, &iter);
}

test "parseManuallyHook: bare destination starts ssh args" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--terminfo=false user@example.com");
    try testing.expectEqual(false, opts.terminfo);
    try testing.expectEqual(true, opts.@"forward-env");
    try testing.expectEqual(@as(usize, 1), opts._ssh_args.items.len);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[0]);
}

test "parseManuallyHook: --shell-integration=false" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try testing.expectEqual(true, opts.@"shell-integration");
    try parseTestArgs(testing.allocator, &opts, "--shell-integration=false user@example.com");
    try testing.expectEqual(false, opts.@"shell-integration");
    try testing.expect(opts._diagnostics.empty());
    try testing.expectEqual(@as(usize, 1), opts._ssh_args.items.len);
}

test "parseManuallyHook: short ssh flags pass through verbatim" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "-p 2222 user@example.com");
    try testing.expectEqual(@as(usize, 3), opts._ssh_args.items.len);
    try testing.expectEqualStrings("-p", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("2222", opts._ssh_args.items[1]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[2]);
}

test "parseManuallyHook: explicit -- separator" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(
        testing.allocator,
        &opts,
        "--verbose -- --some-rare-ssh-arg user@example.com",
    );
    try testing.expectEqual(true, opts.verbose);
    try testing.expectEqual(@as(usize, 2), opts._ssh_args.items.len);
    try testing.expectEqualStrings("--some-rare-ssh-arg", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[1]);
}

test "parseDestination: typical ssh -G output" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\port 22
        \\identityfile ~/.ssh/id_ed25519
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}

test "parseDestination: hostname before user" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\hostname example.com
        \\port 22
        \\user alice
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}

test "parseDestination: missing hostname returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}

test "parseDestination: missing user returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "hostname example.com\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}

test "parseDestination: empty input returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), ""));
}

test "parseDestination: IPv6 hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@::1", result.?);
}
