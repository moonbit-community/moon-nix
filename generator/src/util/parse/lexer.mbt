// Hand-written lexer for the moon.mod / moon.pkg DSL. The grammar is tiny and
// fixed, so a scannerless hand-written tokenizer + recursive-descent parser beats
// pulling in a general parser engine (and avoids the chicken-and-egg of the
// manifest parser depending on a downloaded library). Tokens carry their semantic
// value already stripped: a string's contents (no quotes), a pkgname without `@`.

///|
priv enum Token {
  TId(String) //     identifier; keywords (import/true/false/as/for) are TId too
  TInt(String) //    integer literal text, e.g. "-12" (parsed later)
  TStr(String) //    string contents, quotes removed
  TPkg(String) //    @pkgname, the leading `@` removed
  TEq
  TLParen
  TRParen
  TLBrace
  TRBrace
  TLBrack
  TRBrack
  TComma
  TColon
  TEof
} derive(Eq)

///|
fn is_id_start(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c == '_'
}

///|
fn is_id_char(c : Char) -> Bool {
  is_id_start(c) || c.is_ascii_digit()
}

///|
/// PKGNAME chars: `[a-zA-Z0-9/_]` (the `@` prefix is consumed separately).
fn is_pkg_char(c : Char) -> Bool {
  is_id_char(c) || c == '/'
}

///|
/// Tokenize `input`, skipping whitespace and `//` line comments. `None` on an
/// unterminated string or an unexpected character.
fn tokenize(input : String) -> Array[Token]? {
  let cs = input.to_array()
  let n = cs.length()
  let toks : Array[Token] = []
  let mut i = 0
  while i < n {
    let c = cs[i]
    // Whitespace.
    if c == ' ' || c == '\n' || c == '\t' || c == '\r' {
      i = i + 1
      continue
    }
    // `//` line comment, to end of line.
    if c == '/' && i + 1 < n && cs[i + 1] == '/' {
      i = i + 2
      while i < n && cs[i] != '\n' {
        i = i + 1
      }
      continue
    }
    // Single-char punctuation.
    let punct = match c {
      '=' => Some(TEq)
      '(' => Some(TLParen)
      ')' => Some(TRParen)
      '{' => Some(TLBrace)
      '}' => Some(TRBrace)
      '[' => Some(TLBrack)
      ']' => Some(TRBrack)
      ',' => Some(TComma)
      ':' => Some(TColon)
      _ => None
    }
    match punct {
      Some(t) => {
        toks.push(t)
        i = i + 1
        continue
      }
      None => ()
    }
    // String literal: `"` … `"` (no escapes; body is any non-`"` char).
    if c == '"' {
      i = i + 1
      let sb = StringBuilder()
      while i < n && cs[i] != '"' {
        sb.write_char(cs[i])
        i = i + 1
      }
      if i >= n {
        return None // unterminated string
      }
      i = i + 1 // closing quote
      toks.push(TStr(sb.to_string()))
      continue
    }
    // PKGNAME: `@` followed by pkg chars.
    if c == '@' {
      i = i + 1
      let sb = StringBuilder()
      while i < n && is_pkg_char(cs[i]) {
        sb.write_char(cs[i])
        i = i + 1
      }
      toks.push(TPkg(sb.to_string()))
      continue
    }
    // INT: optional `-` then digits.
    if c == '-' || c.is_ascii_digit() {
      let sb = StringBuilder()
      if c == '-' {
        sb.write_char('-')
        i = i + 1
      }
      while i < n && cs[i].is_ascii_digit() {
        sb.write_char(cs[i])
        i = i + 1
      }
      toks.push(TInt(sb.to_string()))
      continue
    }
    // ID / keyword.
    if is_id_start(c) {
      let sb = StringBuilder()
      while i < n && is_id_char(cs[i]) {
        sb.write_char(cs[i])
        i = i + 1
      }
      toks.push(TId(sb.to_string()))
      continue
    }
    return None // unexpected character
  }
  toks.push(TEof)
  Some(toks)
}
