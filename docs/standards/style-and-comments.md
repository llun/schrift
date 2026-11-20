# Style & comments

- Give types and non-trivial methods `///` doc comments that explain **why** (and,
  for encoder code, exactly which Yjs behavior they mirror). Use inline comments
  for non-obvious protocol/platform behavior. Divide files with `// MARK: -`.
- `final class` for reference/observable types; `struct` for stateless services
  and value models. Full external argument labels; REST-verb method names
  (`create`/`set`/`update`/`delete`/`list`/`favorite`/`duplicate`).
- Import only what a file needs (`Foundation`-only wherever possible).
