# TODO

- [ ] RegExp compilation classifies every error as SyntaxError, including
  UnsupportedFeature. Known; affects
  `test/built-ins/RegExp/named-groups/lookbehind.js` in z-test262. Distinguish
  compilation failures in z-interpreter's `compileRegex` in
  `interpreter_support.zig`; review execution failures separately in `execRaw`
  in `regex_builtins.zig`. The CLI diagnostic change does not fix this debt.
