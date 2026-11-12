### Added

- Typed relation paths (Blueprint #155 Rev. 1): `dartisan model:sync` writes, after each model's class, a `<Model>RelationPath` extension with one getter per relation of its `rels`, so `User.rels.posts.comments.author` is `posts.comments.author`, checked at every step, with the editor offering each model's relations in turn. The path is its string at run time, so `with_`, `whereHas`, `has`, `load` and the others behave as with the string, which stays accepted; `nested(...)` builds the same path from tokens. A relation named like a member of `RelationToken` (`relationTokenMembers`) gets no getter and a warning; after a `MorphTo` relation the path stops.
- New projects get `lib/app/models/models.dart`, exporting every model, which `make:model` keeps up to date, so one import brings every model and its relation paths; in a project without it, `model:sync` suggests it once.

### Changed

- `model:sync` now says when a relation of the `relations:` map cannot be read (a closure with a body, a relation built by a helper), where it left it out without a word: such a relation has no `rels` entry, getter or path.
- `registry_entry_missing` no longer reports a file that declares no class, such as the models barrel.

### Upgrade notes

- After upgrading, `model:sync` adds a `// <dartisan:relation-path>` region at the end of each model file with relations, so `model:sync --check` reports models as out of date until it runs once.
- New public names: `relationTokenMembers` in `package:daravel/daravel.dart`; `ModelsBarrel`, `ProjectPaths.modelsBarrel`, `relationPathPlan`, `replaceRelationPath` and `unreadRelations` in `package:dartisan_cli`.
