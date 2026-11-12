### Changed

- `QueryBuilder.increment`/`decrement`, `ModelQuery.increment`/`decrement`, the column of `ModelQuery.withSum`/`withAvg`/`withMin`/`withMax`, and `ModelCollection.loadMissing` take `Object` names, so a typed column (`User.cols.views`) or relation works there too; anything else is an `ArgumentError` naming the parameter (wave 9, second widening of Review #151 R2). `Model.increment`/`decrement`/`loadMissing` keep `String` (an application model may override them): write `User.cols.views.name` there.
