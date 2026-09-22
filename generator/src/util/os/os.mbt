///|
/// Moon-specific platform policy and a compatibility facade over
/// `moonbitlang/x/os`. New reusable synchronous OS code should use the
/// workspace module directly and handle its `os_error.OSError`.

///|
/// Write `s` to stderr (no trailing newline). The stderr counterpart of the
/// builtin `println` (which only ever writes stdout) — see [`eprintln`].
pub fn eprint(s : String) -> Unit {
  @unix.write_stderr(s) catch {
    _ => ()
  }
}

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
/// Whether stderr is attached to an interactive terminal. Use this to decide
/// between in-place progress and log-friendly line output.
pub fn stderr_is_terminal() -> Bool {
  @unix.stderr_is_terminal()
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
/// Number of logical CPUs the OS reports as currently usable. Falls back to 1
/// because the scheduler treats this as a hard concurrency cap.
pub fn available_parallelism() -> Int {
  @unix.available_parallelism()
}

///|
/// The executable suffix for the host (`.exe` on Windows, else empty).
pub fn exe_suffix() -> String {
  exe_suffix_for(os_kind())
}

///|
/// The executable suffix for a given OS (`.exe` on Windows, else empty). Used by
/// the build layout to name the output binary for the *target* OS, which may
/// differ from the host under a cross build.
fn exe_suffix_for(os : OsKind) -> String {
  match os {
    Windows => ".exe"
    _ => ""
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
/// The `moonc -target <triple>` value for the experimental "new native" backend on
/// this platform, or `None` where moonc has no direct object-code lowering. Unlike
/// [`zig_triple`] (a zig/clang ABI triple) this is moonc's own spelling:
/// `aarch64-apple-darwin` (arm64 macOS) / `x86_64-unknown-linux-gnu` (x86_64 Linux)
/// — the only two hosts moonc can lower straight to a `.o`, matching rust moon's
/// `NativeTarget::from_host`. Windows has no such path → `None`.
pub fn Platform::moonc_native_triple(self : Platform) -> String? {
  match self.os {
    Macos => Some("aarch64-apple-darwin")
    Linux => Some("x86_64-unknown-linux-gnu")
    Windows => None
  }
}

///|
/// Run a program directly (argv, no shell), inheriting stdio. Returns its exit
/// code (-1 on spawn failure). `argv[0]` is the program.
pub fn exec(argv : Array[String]) -> Int {
  if argv.is_empty() {
    return -1
  }
  legacy_exit_code(@unix/process.run(argv[0], argv[1:])) catch {
    _ => -1
  }
}

///|
/// Start a program directly (argv, no shell) WITHOUT waiting; returns its pid
/// (-1 on failure). Pair with [`wait_any`] for the continuous-fill process pool.
pub fn spawn_argv(argv : Array[String]) -> Int {
  if argv.is_empty() {
    return -1
  }
  @unix/process.spawn_orphan(argv[0], argv[1:]) catch {
    _ => -1
  }
}

///|
/// Start a program directly (argv, no shell) WITHOUT waiting, redirecting its
/// stdout+stderr to `outpath` (created/truncated). Pair with [`wait_any`] for
/// parallel CAPTURE — each child writes its own file, so there is no pipe-buffer
/// deadlock. Returns its pid (-1 on failure).
pub fn spawn_argv_to(argv : Array[String], outpath : String) -> Int {
  if argv.is_empty() {
    return -1
  }
  try {
    let output = @unix/process.redirect_to_file(outpath)
    @unix/process.spawn_orphan(argv[0], argv[1:], stdout=output, stderr=output)
  } catch {
    _ => -1
  }
}

///|
/// Run a batch of programs CONCURRENTLY (argv, no shell), each capturing its own
/// stdout+stderr, returning `(exit_code, output)` per command in input order.
/// Each child writes to a per-command temp file under `tmp_dir`; wall-cost is
/// approximately the slowest command, not the sum.
pub fn capture_many_argv(
  cmds : Array[Array[String]],
  tmp_dir : String,
) -> Array[(Int, String)] {
  let n = cmds.length()
  mkdir_p(tmp_dir)
  let codes = FixedArray::make(n, -1)
  let files : Array[String] = []
  let started = FixedArray::make(n, false)
  let pid_to_idx : Map[Int, Int] = Map([])
  let mut live = 0
  for i, c in cmds {
    let f = tmp_dir + "/cap_" + i.to_string() + ".out"
    files.push(f)
    let pid = spawn_argv_to(c, f)
    if pid >= 0 {
      started[i] = true
      pid_to_idx[pid] = i
      live += 1
    }
  }
  for _ in 0..<live {
    let (pid, code) = wait_any()
    match pid_to_idx.get(pid) {
      Some(i) => codes[i] = code
      None => ()
    }
  }
  let out : Array[(Int, String)] = []
  for i in 0..<n {
    // Windows exit statuses use all 32 bits; a negative Int can still be a
    // successfully launched child with useful diagnostics.
    let o = if started[i] { read_file(files[i]) } else { "" }
    out.push((codes[i], o))
  }
  out
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
/// Run a program directly (argv, no shell), capturing stdout and stderr SEPARATELY
/// — returns `(exit_code, stdout, stderr)`. Unlike [`capture_argv`]'s `2>&1` fold,
/// this preserves which stream each line came from, so callers can assert stream
/// discipline (e.g. diagnostics belong on stderr, a `--dry-run` script on stdout).
/// Both streams are drained through pipes while the child runs, without temporary
/// files. NB: the cross-stream interleaving order is NOT recoverable
/// here — use [`capture_argv`] when the merged timeline is what matters.
pub fn capture_argv_split(argv : Array[String]) -> (Int, String, String) {
  if argv.is_empty() {
    return (-1, "", "")
  }
  try {
    let (code, out, err) = @unix/process.collect_output(argv[0], argv[1:])
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
/// Locate an executable on PATH (like `which`/`where`); None if not found.
/// On Windows the C side also tries the `PATHEXT` extensions.
pub fn which(tool : String) -> String? {
  @unix/process.which(tool)
}

///|
/// The current process id — handy for unique temp paths.
pub fn getpid() -> Int {
  @unix.getpid()
}

///|
/// Read all of standard input until EOF (UTF-8, lossily decoded). Used by
/// `moon run -` to take a program's source from a pipe.
pub fn read_stdin() -> String {
  @unix.read_stdin() catch {
    _ => ""
  }
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
/// Create `dst` as a hardlink to existing file `src`. Replaces `dst` first.
/// Returns `false` across filesystems or where the platform denies hardlinks.
pub fn hardlink(src : String, dst : String) -> Bool {
  // Replacement is build-cache policy; the public primitive never removes dst.
  if src == dst || !(@unix/fs.exists(src) catch { _ => false }) {
    return false
  }
  @unix/fs.remove(dst) catch {
    _ => ()
  }
  @unix/fs.hardlink(src, dst) catch {
    _ => return false
  }
  true
}

///|
/// Create many hardlinks concurrently where supported. Each pair replaces `dst`
/// before linking. The returned booleans preserve input order.
pub fn hardlink_many(
  pairs : Array[(String, String)],
  parallel : Int,
) -> Array[Bool] {
  if pairs.is_empty() {
    return []
  }
  // Reject the whole batch before packing: NUL would shift the native records.
  if pairs.any(pair => {
      pair.0.code_units().contains(0) || pair.1.code_units().contains(0)
    }) {
    return Array::make(pairs.length(), false)
  }
  let builder = StringBuilder()
  for pair in pairs {
    builder.write_string(pair.0)
    builder.write_char('\u{0}')
    builder.write_string(pair.1)
    builder.write_char('\u{0}')
  }
  let raw = native_hardlink_many(
    @encoding/utf8.encode(builder.to_string()),
    pairs.length(),
    parallel,
  )
  Array::makei(pairs.length(), i => i < raw.length() && raw[i] != b'\x00')
}

///|
/// Create `dst` as a symlink to `src` without replacing an existing path.
///
/// On Windows, `@fs.symlink` may create an NTFS junction when `src` is an
/// eligible directory. Returns `false` when the destination already exists or
/// the platform denies link creation.
pub async fn symlink(src : String, dst : String) -> Bool {
  @fs.symlink(dst, target=src) catch {
    @os_error.OSError(_) => return false
    err => raise err
  }
  true
}

///|
/// Mark a file executable (POSIX `chmod +x`). No-op on Windows, where
/// executability is determined by extension, not a permission bit.
pub fn set_executable(path : String) -> Unit {
  @unix/fs.set_executable(path) catch {
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
/// Set environment variable `name` to `value` in this process (children spawned
/// afterwards inherit it). Cross-platform (`setenv` / `_putenv_s`).
pub fn setenv(name : String, value : String) -> Unit {
  @unix.setenv(name, value)
}

///|
/// Remove environment variable `name` from this process.
pub fn unsetenv(name : String) -> Unit {
  @unix.unsetenv(name)
}

///|
/// Run a command string through the platform shell (`sh -c` / `cmd /c`),
/// inheriting stdio; returns its exit code. This is the shell escape hatch for the
/// `Command::Shell` variant (user pre-build scripts that genuinely need shell
/// features) — prefer [`exec`] (argv, no shell) for everything mymoon builds itself.
pub fn run(cmd : String) -> Int {
  let pid = spawn(cmd)
  if pid < 0 {
    return -1
  }
  legacy_exit_code(@unix/process.wait_pid(pid)) catch {
    _ => -1
  }
}

///|
#cfg(platform="windows")
#borrow(source, result)
extern "c" fn native_spawn_shell(
  source : Bytes,
  result : FixedArray[Int],
) -> Int = "moonbit_community_unix_process_spawn_shell"

///|
#cfg(platform="windows")
fn spawn_shell(cmd : String) -> Int {
  // cmd /C requires raw shell source, not the public API's MSVCRT argv quoting.
  let result = FixedArray::make(1, 0)
  if native_spawn_shell(@encoding/utf8.encode(cmd), result) != 0 {
    -1
  } else {
    result[0]
  }
}

///|
#cfg(not(platform="windows"))
fn spawn_shell(cmd : String) -> Int {
  @unix/process.spawn_orphan("/bin/sh", ["-c", cmd]) catch {
    _ => -1
  }
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
/// Start a command string under the platform shell WITHOUT waiting; returns its
/// pid (-1 on failure). The shell sibling of [`spawn_argv`]; pair either with
/// [`wait_any`] for the continuous-fill process pool.
pub fn spawn(cmd : String) -> Int {
  spawn_shell(cmd)
}

///|
/// Block until any one child exits, returning (pid, exit code); pid = -1 when
/// there are no children or on error. The wait half of the process pool, shared by
/// both [`spawn`] (shell) and [`spawn_argv`] (argv).
pub fn wait_any() -> (Int, Int) {
  try {
    let (pid, code) = @unix/process.wait_any()
    (pid, legacy_exit_code(code))
  } catch {
    _ => (-1, -1)
  }
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
pub fn append_file(path : String, content : String) -> Unit {
  @unix/fs.write_file(
    path,
    @encoding/utf8.encode(content[:]),
    create_mode=OpenOrCreate,
    sync=NoSync,
    append=true,
  ) catch {
    _ => ()
  }
}

///|
pub fn touch(path : String) -> Unit {
  @unix/fs.touch(path) catch {
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
/// Last modification timestamp in nanoseconds since the Unix epoch, or `-1` if
/// missing.
pub fn mtime(path : String) -> Int64 {
  let (seconds, nanoseconds) = @unix/fs.mtime(path) catch { _ => return -1L }
  if seconds > 9223372036L ||
    (seconds == 9223372036L && nanoseconds > 854775807) ||
    seconds < -9223372037L ||
    (seconds == -9223372037L && nanoseconds < 145224192) {
    return -1L
  }
  if seconds >= 0L {
    seconds * 1_000_000_000L + nanoseconds.to_int64()
  } else {
    (seconds + 1L) * 1_000_000_000L - (1_000_000_000L - nanoseconds.to_int64())
  }
}

///|
/// File size in bytes (`-1` if missing). Paired with [`mtime`] as a cheap
/// `(mtime, size)` content-change proxy for the stat / discovery caches — a
/// `stat` only, no read of the file's bytes.
pub fn size(path : String) -> Int64 {
  @unix/fs.file_size(path) catch {
    _ => -1L
  }
}

///|
/// Fill `out[0]` with mtime_ns and `out[1]` with size_bytes. Both become `-1`
/// when the path is missing. Reuse `out` in hot loops to avoid allocating
/// temporary pair values.
pub fn stat_into(path : String, out : FixedArray[Int64]) -> Unit {
  guard! out.length() >= 2
  out[0] = -1L
  out[1] = -1L
  if path.code_units().contains(0) {
    return
  }
  native_stat(@encoding/utf8.encode(path[:]), out)
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
pub fn read_bytes(path : String) -> Bytes {
  @unix/fs.read_file(path) catch {
    _ => b""
  }
}

///|
pub fn write_bytes(path : String, b : Bytes) -> Unit {
  @unix/fs.write_file(path, b, sync=NoSync) catch {
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
/// A path's kind, via `lstat` (does NOT follow symlinks) — what NAR needs.
pub(all) enum PathKind {
  Missing
  Regular
  Executable
  Directory
  Symlink
} derive(Eq)

///|
pub extend PathKind with Eq::{not_equal, equal}

///|
// NAR uses the owner execute bit, which differs from can_execute's access check.
// Keep that policy here instead of adding Executable to fs.FileKind.
#borrow(path)
extern "c" fn native_nar_path_kind(path : Bytes) -> Int = "moon_os_path_kind"

///|
/// The `lstat` kind of a path.
pub fn path_kind(path : String) -> PathKind {
  match native_nar_path_kind(@encoding/utf8.encode(path[:])) {
    1 => Regular
    2 => Executable
    3 => Directory
    4 => Symlink
    _ => Missing
  }
}

///|
/// The target of a symlink (empty string on error).
pub fn readlink(path : String) -> String {
  @unix/fs.readlink(path) catch {
    _ => ""
  }
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

///|
#borrow(path, out)
extern "c" fn native_stat(path : Bytes, out : FixedArray[Int64]) -> Unit = "moon_os_stat"

///|
#borrow(blob)
extern "c" fn native_hardlink_many(
  blob : Bytes,
  count : Int,
  parallel : Int,
) -> Bytes = "moon_os_hardlink_many"
