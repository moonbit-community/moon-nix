///|
/// Error-handling helpers over
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
/// The process's current working directory.
pub fn cwd() -> String {
  @unix.cwd() catch {
    _ => ""
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
pub fn realpath(path : String) -> String? {
  Some(@unix/fs.realpath(path)) catch {
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
/// Keep the compiler's shell-style signal convention.
fn legacy_exit_code(code : Int) -> Int {
  if code < 0 {
    128 - code
  } else {
    code
  }
}

///|
pub fn read_file(path : String) -> String {
  @encoding/utf8.decode_lossy(@unix/fs.read_file(path)[:]) catch {
    _ => abort("failed to read file: " + path)
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
/// `.` and `..` are excluded; unreadable directories are errors.
pub fn list_dir(path : String) -> Array[DirEntry] {
  let names = @unix/fs.readdir(path) catch {
    _ => abort("failed to list directory: " + path)
  }
  let entries : Array[DirEntry] = []
  for name in names {
    let kind = @unix/fs.kind(path + "/" + name) catch {
      _ => abort("failed to inspect directory entry: " + path + "/" + name)
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
