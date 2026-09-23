///|
/// Moon-specific platform policy and a compatibility facade over
/// `moonbitlang/x/os`. New reusable synchronous OS code should use the
/// workspace module directly and handle its `os_error.OSError`.

///|
/// Write `s` followed by a newline to stderr. Use for everything the Unix stream
/// contract puts on stderr — diagnostics, progress/status, warnings and error
/// messages — keeping stdout clean for machine-readable data (dry-run scripts,
/// `--json` output). The CLI's stdout-vs-stderr split mirrors upstream `moon`.
pub fn eprintln(s : String) -> Unit {
  @unix.write_stderr(s + "\n") catch {
    _ => ()
  }
}

///|
/// The host OS reported by `moonbitlang/x/os`.
pub(all) enum OsKind {
  Linux
  Macos
  Windows
} derive(Eq)

///|
pub extend OsKind with Eq::{not_equal, equal}

///|
pub fn os_kind() -> OsKind {
  match @unix.os_kind() {
    @unix.Linux => Linux
    @unix.Macos => Macos
    @unix.Windows => Windows
  }
}

///|
/// Parse an OS name (as accepted by `--target-os`) into an `OsKind`. Accepts the
/// canonical names plus `darwin` (the zig/llvm spelling of macOS). `None` for an
/// unrecognized name.
pub fn OsKind::parse(s : String) -> OsKind? {
  match s {
    "windows" | "win" => Some(Windows)
    "macos" | "darwin" | "mac" => Some(Macos)
    "linux" => Some(Linux)
    _ => None
  }
}

///|
/// Host platform used to evaluate conditional imports and label plans.
pub(all) struct Platform {
  os : OsKind
} derive(Eq)

///|
pub extend Platform with Eq::{not_equal, equal}

///|
pub fn Platform::host() -> Platform {
  { os: os_kind() }
}

///|
/// Only Linux and macOS targets are supported by this exporter.
pub fn Platform::parse(s : String) -> Platform? {
  match OsKind::parse(s) {
    Some(Linux) => Some({ os: Linux })
    Some(Macos) => Some({ os: Macos })
    _ => None
  }
}

///|
pub fn Platform::tag(self : Platform) -> String {
  match self.os {
    Linux => "linux"
    Macos => "macos"
    Windows => "windows"
  }
}

///|
pub fn Platform::matches(self : Platform, cond : Platform) -> Bool {
  self.os == cond.os
}

///|
/// Run a program with its STDIN redirected to read from
/// `stdin_path` (a file). For running an `__moonbit_unstable_prebuild` script: it is
/// fed the JSON payload on fd 0 instead of inheriting our stdin, so a script that
/// reads fd 0 cannot block on an interactive TTY. Returns `(exit, stdout, stderr)`.
pub fn capture_argv_stdin(
  argv : Array[String],
  stdin_path : String,
) -> (Int, String, String) {
  if argv.is_empty() {
    return (-1, "", "")
  }
  try {
    let input = @unix/process.redirect_from_file(stdin_path)
    let (code, out, err) = @unix/process.collect_output(
      argv[0],
      argv[1:],
      stdin=input,
    )
    (
      legacy_exit_code(code),
      @encoding/utf8.decode_lossy(out[:]),
      @encoding/utf8.decode_lossy(err[:]),
    )
  } catch {
    _ => (-1, "", "")
  }
}

///|
/// The current process id — handy for unique temp paths.
pub fn getpid() -> Int {
  @unix.getpid()
}

///|
/// The process's current working directory, with `/` separators on Windows for
/// the build system's path joins, ancestor walks, and package comparisons.
pub fn cwd() -> String {
  build_path(@unix.cwd(), os_kind()) catch {
    _ => ""
  }
}

///|
/// The compiler uses slash-separated paths internally. Keep POSIX backslashes
/// (legal filename characters) and opaque Windows device namespaces untouched.
fn build_path(path : String, kind : OsKind) -> String {
  if kind is Windows &&
    !path.has_prefix("\\\\?\\") &&
    !path.has_prefix("\\\\.\\") {
    path.replace_all(old="\\", new="/")
  } else {
    path
  }
}

///|
/// Change the process working directory. `true` on success.
pub fn chdir(path : String) -> Bool {
  @unix.chdir(path) catch {
    _ => return false
  }
  true
}

///|
/// The canonical absolute path: symlinks and `.`/`..` resolved (POSIX realpath).
/// `None` if the path can't be resolved (e.g. it doesn't exist). On macOS this
/// folds the `/var`→`/private/var` and `/tmp`→`/private/tmp` symlinks.
/// Ordinary Windows drive and UNC paths use the compiler's `/` separators.
pub fn realpath(path : String) -> String? {
  Some(build_path(@unix/fs.realpath(path), os_kind())) catch {
    _ => None
  }
}

///|
/// Recursively delete a path (the portable `rm -rf`). No-op if absent.
pub fn remove_all(path : String) -> Unit {
  @unix/fs.remove_all(path) catch {
    _ => ()
  }
}

///|
pub fn args() -> Array[String] {
  @unix.args()
}

///|
pub fn getenv(name : String) -> String? {
  @unix.getenv(name)
}

///|
pub fn getenv_or(name : String, fallback : String) -> String {
  getenv(name).unwrap_or(fallback)
}

///|
/// Keep the compiler's shell-style signal convention without interpreting
/// Windows high-bit exit codes as POSIX signals.
fn legacy_exit_code(code : Int) -> Int {
  if os_kind() != Windows && code < 0 {
    128 - code
  } else {
    code
  }
}

///|
/// Terminate the process immediately with status `code`.
pub fn exit(code : Int) -> Unit {
  @unix.exit(code)
}

///|
pub fn read_file(path : String) -> String {
  @encoding/utf8.decode_lossy(@unix/fs.read_file(path)[:]) catch {
    _ => ""
  }
}

///|
pub fn write_file(path : String, content : String) -> Unit {
  @unix/fs.write_file(path, @encoding/utf8.encode(content[:]), sync=NoSync) catch {
    _ => ()
  }
}

///|
pub fn exists(path : String) -> Bool {
  @unix/fs.exists(path) catch {
    _ => false
  }
}

///|
/// Monotonic wall-clock in nanoseconds — for profiling.
pub fn now_ns() -> Int64 {
  @unix.now_ns()
}

///|
pub fn mkdir_p(path : String) -> Unit {
  @unix/fs.mkdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
/// One entry of a directory listing, tagged with its file-system kind.
pub(all) enum DirEntry {
  Dir(String)
  File(String)
  Other(String)
}

///|
/// List the immediate children of a directory (names only, not recursive).
/// `.` and `..` are excluded; an unreadable directory yields an empty list.
pub fn list_dir(path : String) -> Array[DirEntry] {
  let names = @unix/fs.readdir(path) catch {
    _ => return []
  }
  let entries : Array[DirEntry] = []
  for name in names {
    let kind = @unix/fs.kind(path + "/" + name) catch {
      _ => @unix/fs.Unknown
    }
    entries.push(
      match kind {
        @unix/fs.Directory => Dir(name)
        @unix/fs.Regular => File(name)
        _ => Other(name)
      },
    )
  }
  entries
}
