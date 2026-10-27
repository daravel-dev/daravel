# Changelog

## Unreleased

- Fixed: `allowedWiths` is matched by full path, so `author` no longer opens `?withs[]=author.posts` or a relation the model does not define (which was a 500).
- Fixed: `?visibles[]=` un-hides only attributes listed in the new `QueryFilter.allowedVisibles` (empty by default; laravel-teorion lets a client un-hide anything, including `hidden` password hashes); `DisallowedVisibleException` (400) in strict mode.
- Fixed: `scopes[0][params]=x` (not a map) is read as no parameters instead of a 500.
- Fixed: `?per_page=` and `?max_results=` are clamped to `TEORION_MAX_PER_PAGE` (`TeorionConfig.maxPerPage`, 100 like `baseRules`); a value below 1 means `TEORION_DEFAULT_PER_PAGE` (`-1` returned every row, `0` was a division by zero in the paginator).

## 1.13.0

- Version aligned with Daravel 1.13.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.12.0

- First release: a port of laravel-teorion 2.4 (`QueryFilter<T>`, `Filter.*`, `filterAndPaginate`, `findFiltered`, `filter`, `withQueryFilters`, `QueryAudited`), with its request format; `withs[]=relation:columns` within `allowedWithColumns` (`DisallowedWithColumnsException` otherwise).
