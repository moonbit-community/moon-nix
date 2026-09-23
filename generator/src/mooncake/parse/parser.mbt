// Hand-written recursive-descent parser for moon.mod / moon.pkg. Produces the
// lowered `(key, @config.Value)` entries directly — no intermediate AST, no
// general parser engine. The grammar (from the old .sdf files):
//
//   File  = Entry*
//   Entry = ID "=" Value                         (assignment)
//         | ID "(" {Arg ","}* ")"                (apply, e.g. options(...))
//         | "import" "{" {ImpItem ","}* "}"      (deps / imports)
//         | "import" "{" … "}" "for" STRING      (test-only imports)
//   Value = STRING | INT | "true" | "false"
//         | "[" {Value ","}* "]" | "{" {Pair ","}* "}"
//   Pair  = STRING ":" Value
//   Arg   = (STRING | ID) ":" Value
//   ImpItem = STRING ("as" PKGNAME | PKGNAME)?   | STRING ":" Value
//
// All comma lists allow a trailing comma.

///|
priv struct Parser {
  toks : Array[Token]
  mut pos : Int
}

///|
/// One `import {}` item: either a path with an optional import_alias, or a `name: spec`.
priv enum ImpItem {
  IItem(String, String?) //   path/name, optional import_alias (pkgname, `@` removed)
  ISpec(String, @config.Value) // name : value
}

///|
fn Parser::peek(self : Parser) -> Token {
  if self.pos < self.toks.length() {
    self.toks[self.pos]
  } else {
    TEof
  }
}

///|
fn Parser::advance(self : Parser) -> Token {
  let t = self.peek()
  self.pos = self.pos + 1
  t
}

///|
/// Consume a token equal to `t`; return false if the next token differs.
fn Parser::eat(self : Parser, t : Token) -> Bool {
  if self.peek() == t {
    self.pos = self.pos + 1
    true
  } else {
    false
  }
}

///|
fn to_int(t : String) -> Int {
  @string.parse_int(t) catch {
    _ => 0
  }
}

///|
fn Parser::parse_value(self : Parser) -> @config.Value? {
  match self.peek() {
    TStr(s) => {
      self.pos = self.pos + 1
      Some(Str(s))
    }
    TInt(t) => {
      self.pos = self.pos + 1
      Some(Int(to_int(t)))
    }
    TId("true") => {
      self.pos = self.pos + 1
      Some(Bool(true))
    }
    TId("false") => {
      self.pos = self.pos + 1
      Some(Bool(false))
    }
    TLBrack => self.parse_array()
    TLBrace => self.parse_object()
    _ => None
  }
}

///|
/// `"[" {Value ","}* "]"`, trailing comma allowed.
fn Parser::parse_array(self : Parser) -> @config.Value? {
  guard self.eat(TLBrack) else { return None }
  let items : Array[@config.Value] = []
  while self.peek() != TRBrack {
    guard self.parse_value() is Some(v) else { return None }
    items.push(v)
    if !self.eat(TComma) {
      break
    }
  }
  guard self.eat(TRBrack) else { return None }
  Some(Array(items))
}

///|
/// `"{" {STRING ":" Value ","}* "}"`, trailing comma allowed.
fn Parser::parse_object(self : Parser) -> @config.Value? {
  guard self.eat(TLBrace) else { return None }
  let m : Map[String, @config.Value] = Map([])
  while self.peek() != TRBrace {
    let key = match self.advance() {
      TStr(s) => s
      _ => return None
    }
    guard self.eat(TColon) else { return None }
    guard self.parse_value() is Some(v) else { return None }
    m[key] = v
    if !self.eat(TComma) {
      break
    }
  }
  guard self.eat(TRBrace) else { return None }
  Some(Object(m))
}

///|
/// `{ImpItem ","}*` until the closing brace (not consumed here).
fn Parser::parse_import_items(self : Parser) -> Array[ImpItem]? {
  let items : Array[ImpItem] = []
  while self.peek() != TRBrace {
    let s = match self.advance() {
      TStr(s) => s
      _ => return None
    }
    match self.peek() {
      TColon => {
        self.pos = self.pos + 1
        guard self.parse_value() is Some(v) else { return None }
        items.push(ISpec(s, v))
      }
      TId("as") => {
        self.pos = self.pos + 1
        let pkg = match self.advance() {
          TPkg(p) => p
          _ => return None
        }
        items.push(IItem(s, Some(pkg)))
      }
      TPkg(p) => {
        self.pos = self.pos + 1
        items.push(IItem(s, Some(p)))
      }
      _ => items.push(IItem(s, None))
    }
    if !self.eat(TComma) {
      break
    }
  }
  Some(items)
}

///|
fn Parser::parse_entry(
  self : Parser,
  is_mod : Bool,
) -> (String, @config.Value)? {
  match self.peek() {
    TId("import") => {
      self.pos = self.pos + 1
      guard self.eat(TLBrace) else { return None }
      guard self.parse_import_items() is Some(items) else { return None }
      guard self.eat(TRBrace) else { return None }
      // optional `for STRING` → a test-only import section. `for "wbtest"` feeds
      // the whitebox-test target, `for "test"` the blackbox-test target; the items
      // are lowered like regular pkg imports but kept under a distinct key.
      if self.peek() == TId("for") {
        self.pos = self.pos + 1
        let section = match self.advance() {
          TStr(s) => s
          _ => return None
        }
        let (_, arr) = lower_pkg_imports(items)
        // Internal `for-<section>` key, distinct from any user-writable manifest
        // key. `for "test"`/`for "wbtest"` feed the test targets; `for "native"` /
        // `for "wasm-gc"` / … are backend-conditional imports. This is the ONLY
        // producer of these edges in the DSL — the legacy literal `test-import` /
        // `wbtest-import` keys are deliberately NOT recognized by `decode_pkg`.
        return Some(("for-" + section, arr))
      }
      Some(
        if is_mod {
          lower_mod_deps(items)
        } else {
          lower_pkg_imports(items)
        },
      )
    }
    TId(id) => {
      self.pos = self.pos + 1
      match self.peek() {
        TEq => {
          self.pos = self.pos + 1
          guard self.parse_value() is Some(v) else { return None }
          Some((id, v))
        }
        TLParen => {
          self.pos = self.pos + 1
          let m : Map[String, @config.Value] = Map([])
          while self.peek() != TRParen {
            let k = match self.advance() {
              TStr(s) => s
              TId(s) => s
              _ => return None
            }
            guard self.eat(TColon) else { return None }
            guard self.parse_value() is Some(v) else { return None }
            m[k] = v
            if !self.eat(TComma) {
              break
            }
          }
          guard self.eat(TRParen) else { return None }
          Some((id, Object(m)))
        }
        _ => None
      }
    }
    _ => None
  }
}

///|
fn Parser::parse_file(
  self : Parser,
  is_mod : Bool,
) -> Array[(String, @config.Value)]? {
  let entries : Array[(String, @config.Value)] = []
  while self.peek() != TEof {
    guard self.parse_entry(is_mod) is Some(e) else { return None }
    entries.push(e)
  }
  Some(entries)
}

// ============================ import lowering ============================

///|
/// moon.mod `import { ... }` → a `("deps", Object{name: spec})` entry. Item forms:
///   - `"name@version"`          → registry (bare version)
///   - `"name": { ...spec... }`  → object form, taken verbatim
/// A `moon.mod` dependency is ALWAYS a registry version: the `@<ref>` is taken as the
/// version verbatim. The DSL has no syntax for a local-path (or VCS) dep — a
/// `path+…`/`git+…` ref just becomes a bad version, rejected at decode. (Develop
/// multiple modules together via `moon.work` members.)
fn lower_mod_deps(items : Array[ImpItem]) -> (String, @config.Value) {
  let m : Map[String, @config.Value] = Map([])
  for it in items {
    match it {
      IItem(s, _) => {
        // import_alias is meaningless for a module dep — ignore it
        let (name, ref_) = split_name_ref(s)
        m[name] = Str(ref_)
      }
      ISpec(name, v) => m[name] = v
    }
  }
  ("deps", Object(m))
}

///|
/// moon.pkg `import { "pkg/path" @import_alias, ... }` → an `("import", Array)` entry.
fn lower_pkg_imports(items : Array[ImpItem]) -> (String, @config.Value) {
  let arr : Array[@config.Value] = []
  for it in items {
    match it {
      IItem(p, import_alias) =>
        match import_alias {
          Some(pkg) => arr.push(Object({ "path": Str(p), "alias": Str(pkg) }))
          None => arr.push(Str(p))
        }
      // A `"name": spec` item in a package_name import is unusual; keep the name.
      ISpec(name, _) => arr.push(Str(name))
    }
  }
  ("import", Array(arr))
}

// ============================ string helpers ============================

///|
/// Split `name@rev` at the FIRST `@`. The first (not last) `@` because a git URL
/// rev may itself contain `@` (`ssh://git@host/…`), while a module name never
/// does. No `@` → empty rev.
fn split_name_ref(s : String) -> (String, String) {
  split_first(s, '@')
}

///|
/// Split `s` at the first `ch` into (before, after); no `ch` → (s, "").
fn split_first(s : String, ch : Char) -> (String, String) {
  match s.split_once(ch.to_string()) {
    Some((a, b)) => (a.to_owned(), b.to_owned())
    None => (s, "")
  }
}

// ============================ entry points ============================

///|
fn parse_dsl(input : String, is_mod : Bool) -> Array[(String, @config.Value)]? {
  guard tokenize(input) is Some(toks) else { return None }
  let p = Parser::{ toks, pos: 0 }
  guard p.parse_file(is_mod) is Some(entries) else { return None }
  guard p.peek() == TEof else { return None } // trailing garbage
  Some(entries)
}

///|
/// Parse a moon.mod file (assignments + module-dep `import {}` block).
pub fn parse_mod(input : String) -> Array[(String, @config.Value)]? {
  parse_dsl(input, true)
}

///|
/// Parse a moon.pkg file (assignments + package_name `import {}` / `options()` blocks).
pub fn parse_pkg(input : String) -> Array[(String, @config.Value)]? {
  parse_dsl(input, false)
}
