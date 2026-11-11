### Added

- ORM: typed relations (wave 9, W9.3). `dartisan model:sync` reads a model's `relations:` map and writes `static const rels = (...)` (one `RelationToken<Model, Related>` per relation), a typed getter (`user.posts`, `ModelCollection<Post>`; `Post?` for a single model, `Model?` for `MorphTo`) and a loader (`user.loadPosts()`). `User.rels.` lists the relations; `User.rels.posts.nested(Post.rels.comments)` is `posts.comments` and only follows the models; `User.rels.posts.only([Post.cols.id, Post.cols.title])` is `posts:id,title` and only takes the related model's columns. A token is the relation's name at run time: `with_`, `withCount`, `load` and the others see the same string. A relation named like a column accessor, a `Model` member or a keyword is left out with a warning; `loadMissing` is not generated (it is `Model.loadMissing`).

### Changed

- `ModelQuery.whereHas`, `orWhereHas`, `has`, `whereDoesntHave`, `orWhereDoesntHave` and `doesntHave` take `Object` relations (a `String` or a typed relation); anything else is an `ArgumentError` naming the parameter.

### Upgrade notes

- `package:daravel` exports `RelationToken` and `RelationColumns`. An application type of either name now needs a prefix or `hide`.
- After `dartisan model:sync`, a model gets a getter and a `load…()` per relation; a member of the model's own class with the same name (outside the generated region) now clashes and does not compile: rename one of them.
