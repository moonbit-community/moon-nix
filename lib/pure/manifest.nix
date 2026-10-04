# Parse manifests during evaluation. No executable parser or generated files.
{ lib }:
let
  fail = message: throw "moon-nix manifest: ${message}";
  tokenize =
    input:
    let
      n = builtins.stringLength input;
      tail = i: builtins.substring i (n - i) input;
      scanString =
        start: i:
        if i >= n then
          fail "unterminated string"
        else if builtins.substring i 1 input == "\\" then
          scanString start (i + 2)
        else if builtins.substring i 1 input == "\"" then
          {
            token = {
              kind = "string";
              value = builtins.fromJSON (builtins.substring start (i - start + 1) input);
            };
            next = i + 1;
          }
        else
          scanString start (i + 1);
      scan =
        i:
        if i >= n then
          [ ]
        else
          let
            rest = tail i;
            c = builtins.substring i 1 input;
            whitespace = builtins.match "([[:space:]]+)(.*)" rest;
            comment = builtins.match "(//[^\n]*)(.*)" rest;
            word = builtins.match "([a-zA-Z_][a-zA-Z_0-9]*)(.*)" rest;
            alias = builtins.match "(@[a-zA-Z_0-9/]+)(.*)" rest;
            number = builtins.match "(-?[0-9]+)(.*)" rest;
            consume = match: kind: {
              token = {
                inherit kind;
                value = builtins.head match;
              };
              next = i + builtins.stringLength (builtins.head match);
            };
            t =
              if c == "\"" then
                scanString i (i + 1)
              else if word != null then
                consume word "word"
              else if alias != null then
                consume alias "alias"
              else if number != null then
                consume number "number"
              else if
                builtins.elem c [
                  "="
                  "("
                  ")"
                  "{"
                  "}"
                  "["
                  "]"
                  ","
                  ":"
                ]
              then
                {
                  token = {
                    kind = c;
                    value = c;
                  };
                  next = i + 1;
                }
              else
                fail "unexpected character at byte ${toString i}: ${c}";
          in
          if whitespace != null then
            scan (i + builtins.stringLength (builtins.head whitespace))
          else if comment != null then
            scan (i + builtins.stringLength (builtins.head comment))
          else
            [ t.token ] ++ scan t.next;
    in
    scan 0;
  parseDSL =
    kind: input:
    let
      tokens = tokenize input;
      count = builtins.length tokens;
      at =
        i:
        if i < count then
          builtins.elemAt tokens i
        else
          {
            kind = "eof";
            value = "<eof>";
          };
      expect = i: k: if (at i).kind == k then i + 1 else fail "expected ${k}, got ${(at i).value}";
      list =
        close: item: i:
        if (at i).kind == close then
          {
            value = [ ];
            next = i + 1;
          }
        else
          let
            first = item i;
            rest =
              if (at first.next).kind == "," then
                list close item (first.next + 1)
              else
                {
                  value = [ ];
                  next = expect first.next close;
                };
          in
          {
            value = [ first.value ] ++ rest.value;
            next = rest.next;
          };
      pair =
        i:
        let
          key = at i;
          v = value (expect (i + 1) ":");
        in
        if
          !builtins.elem key.kind [
            "string"
            "word"
          ]
        then
          fail "expected object key"
        else
          {
            value = {
              name = key.value;
              value = v.value;
            };
            next = v.next;
          };
      object =
        close: i:
        let
          result = list close pair i;
        in
        result // { value = builtins.listToAttrs result.value; };
      value =
        i:
        let
          t = at i;
        in
        if t.kind == "string" then
          {
            value = t.value;
            next = i + 1;
          }
        else if t.kind == "number" then
          {
            value = builtins.fromJSON t.value;
            next = i + 1;
          }
        else if
          t.kind == "word"
          && builtins.elem t.value [
            "true"
            "false"
          ]
        then
          {
            value = t.value == "true";
            next = i + 1;
          }
        else if t.kind == "[" then
          list "]" value (i + 1)
        else if t.kind == "{" then
          object "}" (i + 1)
        else
          fail "expected value, got ${t.value}";
      importItem =
        i:
        let
          t = at i;
          hasSpec = (at (i + 1)).kind == ":";
          spec = value (i + 2);
          hasAs = (at (i + 1)).value == "as";
          a = at (i + (if hasAs then 2 else 1));
          hasAlias = hasAs || a.kind == "alias";
          aliasValue = lib.removePrefix "@" a.value;
        in
        if t.kind != "string" then
          fail "expected quoted import path"
        else if hasSpec then
          {
            value = {
              path = t.value;
              inherit (spec) value;
            };
            next = spec.next;
          }
        else if
          hasAlias
          && !builtins.elem a.kind [
            "word"
            "alias"
          ]
        then
          fail "expected import alias"
        else
          {
            value = {
              path = t.value;
            }
            // lib.optionalAttrs hasAlias { alias = aliasValue; };
            next = i + 1 + (if hasAlias then (if hasAs then 2 else 1) else 0);
          };
      entries =
        i: result:
        if i == count then
          result
        else
          let
            key = at i;
            imports = list "}" importItem (expect (i + 1) "{");
            conditional = (at imports.next).value == "for";
            section = at (imports.next + 1);
            importKey =
              if conditional then
                "for-${section.value}"
              else if kind == "module" then
                "deps"
              else
                "import";
            modDeps = builtins.listToAttrs (
              map (
                x:
                let
                  parts = lib.splitString "@" x.path;
                in
                {
                  name = builtins.head parts;
                  value =
                    x.value or (
                      if builtins.length parts == 2 then
                        builtins.elemAt parts 1
                      else
                        fail "module dependency needs a version: ${x.path}"
                    );
                }
              ) imports.value
            );
            importValue =
              if kind == "module" && !conditional then
                modDeps
              else
                map (x: if x ? alias then { inherit (x) path alias; } else x.path) imports.value;
            v =
              if (at (i + 1)).kind == "=" then
                value (i + 2)
              else if (at (i + 1)).kind == "(" then
                object ")" (i + 2)
              else
                fail "expected assignment or options block after ${key.value}";
          in
          if key.kind != "word" then
            fail "expected entry name"
          else if key.value == "import" then
            if conditional && section.kind != "string" then
              fail "expected quoted import condition"
            else
              entries (imports.next + (if conditional then 2 else 0)) (
                result
                // {
                  ${importKey} =
                    if kind == "module" && !conditional then
                      (result.${importKey} or { }) // importValue
                    else
                      (result.${importKey} or [ ]) ++ importValue;
                }
              )
          else
            entries v.next (
              result
              // {
                ${key.value} =
                  if
                    builtins.elem key.value [
                      "rule"
                      "dev_build"
                    ]
                    && (at (i + 1)).kind == "("
                  then
                    (result.${key.value} or [ ]) ++ [ v.value ]
                  else
                    v.value;
              }
            );
    in
    entries 0 { };
  normalize =
    raw:
    let
      combined = raw // (raw.options or { });
    in
    lib.mapAttrs' (name: value: {
      name = builtins.replaceStrings [ "_" ] [ "-" ] name;
      inherit value;
    }) (builtins.removeAttrs combined [ "options" ]);
  read =
    kind: root:
    let
      stem = if kind == "module" then "moon.mod" else "moon.pkg";
      dsl = root + "/${stem}";
      json = root + "/${stem}.json";
    in
    normalize (
      if builtins.pathExists dsl then
        parseDSL kind (builtins.readFile dsl)
      else if builtins.pathExists json then
        builtins.fromJSON (builtins.readFile json)
      else
        fail "missing ${stem} in ${toString root}"
    );
in
{
  inherit
    tokenize
    parseDSL
    normalize
    read
    ;
}
