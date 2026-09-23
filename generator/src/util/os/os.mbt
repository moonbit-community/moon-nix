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
/// The host operating-system family, resolved at COMPILE time in the C stub
/// (`#ifdef _WIN32` / `__APPLE__`) — never sniffed from env vars or `uname`.
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
/// The C toolchain / ABI axis of a target platform. It matters mainly on Windows,
/// where `Gnu` (mingw-w64) and `Msvc` are incompatible ABIs needing different link
/// flags; other OSes have one mainstream toolchain today and ignore it. `None` in a
/// [`Platform`] means "the OS default" — on Windows that is `Gnu` (mingw-w64),
/// which zig bundles, so a cross build needs no external SDK.
pub(all) enum Toolchain {
  Gnu
  Msvc
} derive(Eq)

///|
pub extend Toolchain with Eq::{not_equal, equal}

///|
/// Parse a toolchain name (the `-<toolchain>` part of `--platform windows-gnu`).
fn Toolchain::parse(s : String) -> Toolchain? {
  match s {
    "gnu" | "mingw" => Some(Gnu)
    "msvc" => Some(Msvc)
    _ => None
  }
}

///|
/// A target platform: an OS plus an optional toolchain/ABI override. This is the
/// canonical descriptor of what a native build targets (the thing `--platform`
/// selects); `toolchain = None` means the OS default. The architecture is implied
/// by the OS (mymoon's native backend is x86_64 on Linux/Windows, arm64 on macOS),
/// so it is derived in [`zig_triple`] rather than carried as a dead field.
pub(all) struct Platform {
  os : OsKind
  toolchain : Toolchain?
} derive(Eq)

///|
pub extend Platform with Eq::{not_equal, equal}

///|
/// The host platform (OS default toolchain). A native build whose `Platform`
/// equals this needs no cross toolchain.
pub fn Platform::host() -> Platform {
  { os: os_kind(), toolchain: None, }
}

///|
/// Parse a `--platform` value `<os>[-<toolchain>]` (e.g. `linux`, `windows`,
/// `windows-gnu`, `windows-msvc`). `None` for an unrecognized value.
pub fn Platform::parse(s : String) -> Platform? {
  match s.split_once("-") {
    // `<os>-<toolchain>`, e.g. windows-gnu.
    Some((os_s, tc_s)) =>
      match
        (OsKind::parse(os_s.to_owned()), Toolchain::parse(tc_s.to_owned())) {
        (Some(os), Some(tc)) => Some({ os, toolchain: Some(tc), })
        // Not an os-toolchain pair → try the whole string as a bare OS.
        _ =>
          match OsKind::parse(s) {
            Some(os) => Some({ os, toolchain: None, })
            None => None
          }
      }
    None =>
      match OsKind::parse(s) {
        Some(os) => Some({ os, toolchain: None, })
        None => None
      }
  }
}

///|
/// A short, filesystem-safe tag for this platform, for keying the `_build` tree so
/// cross builds to different platforms don't share `.core`/`.o` paths. The default
/// ABI is resolved (Windows → `gnu`), so `windows` and `windows-gnu` map to one
/// dir. Examples: `linux`, `macos`, `windows-gnu`, `windows-msvc`.
pub fn Platform::tag(self : Platform) -> String {
  let os = match self.os {
    Windows => "windows"
    Macos => "macos"
    Linux => "linux"
  }
  let abi = match self.toolchain {
    Some(Gnu) => "gnu"
    Some(Msvc) => "msvc"
    None =>
      match self.os {
        Windows => "gnu" // the resolved default ABI on Windows
        _ => ""
      }
  }
  if abi == "" {
    os
  } else {
    os + "-" + abi
  }
}

///|
/// Whether this (the active build platform) satisfies a platform condition. The
/// OS must match; a condition toolchain must match the active ABI
/// (the default ABI being `Gnu` — mingw on Windows, glibc on Linux), while a
/// condition with no toolchain constrains only the OS.
pub fn Platform::matches(self : Platform, cond : Platform) -> Bool {
  if self.os != cond.os {
    return false
  }
  match cond.toolchain {
    None => true
    Some(tc) => {
      let active = match self.toolchain {
        Some(t) => t
        None => Gnu
      }
      active == tc
    }
  }
}

///|
/// The `x86_64`/`arm64` zig/clang target triple for this platform, for `zig cc
/// -target` / `zig build-obj -target` cross compilation. The Windows ABI suffix
/// honors the toolchain: `Gnu` → `-gnu` (mingw-w64; ships its own headers/import
/// libs), else `-msvc` (the default — the ABI a native Windows build uses and the
/// only one moonbitlang/async supports; needs the MSVC SDK supplied out-of-band via
/// `xwin`/`ZIG_LIBC`).
pub fn Platform::zig_triple(self : Platform) -> String {
  match self.os {
    Windows =>
      match self.toolchain {
        // Default (and explicit Gnu) = mingw-w64: zig BUNDLES its headers + import
        // libs, so a cross build works out of the box with no SDK download. Msvc
        // must be asked for explicitly — its ABI needs the MSVC SDK supplied
        // out-of-band (xwin + ZIG_LIBC), so it is a poor zero-config default.
        Some(Gnu) | None => "x86_64-windows-gnu"
        Some(Msvc) => "x86_64-windows-msvc"
      }
    // MoonBit's native backend targets arm64 macOS only (no x86_64 macOS).
    Macos => "aarch64-macos"
    Linux => "x86_64-linux-gnu"
  }
}

///|
/// Run a program directly (argv, no shell), capturing stdout AND stderr merged
/// into one stream (the `2>&1` fold, done without a shell). Returns
/// (exit code, captured output).
pub fn capture_argv(argv : Array[String]) -> (Int, String) {
  if argv.is_empty() {
    return (-1, "")
  }
  try {
    let (code, output) = @unix/process.collect_output_merged(
      argv[0],
      argv[1:].to_owned(),
    )
    (legacy_exit_code(code), @encoding/utf8.decode_lossy(output[:]))
  } catch {
    _ => (-1, "")
  }
}

///|
/// Like [`capture_argv_split`] but with the child's STDIN redirected to read from
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
  if path.contains("\u{0}") {
    return []
  }
  let status = FixedArray::make(1, 0)
  let raw = native_list_dir(@encoding/utf8.encode(path[:]), status)
  if status[0] != 0 {
    return []
  }
  let entries : Array[DirEntry] = []
  let mut cursor = 0
  while cursor < raw.length() {
    let kind = raw[cursor]
    let name_start = cursor + 1
    let mut name_end = name_start
    while name_end < raw.length() && raw[name_end] != b'\x00' {
      name_end += 1
    }
    if name_end == raw.length() {
      return []
    }
    let name = @encoding/utf8.decode_lossy(raw[name_start:name_end])
    entries.push(
      match kind {
        b'd' => Dir(name)
        b'f' => File(name)
        _ => Other(name)
      },
    )
    cursor = name_end + 1
  }
  entries
}

///|
// POSIX follows links; Windows classifies from directory-entry attributes,
// including non-symlink reparse points such as cloud placeholders.
#borrow(path, status)
extern "c" fn native_list_dir(path : Bytes, status : FixedArray[Int]) -> Bytes = "moon_os_list_dir"
