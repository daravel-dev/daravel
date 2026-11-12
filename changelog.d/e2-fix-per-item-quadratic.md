### Fixed

- Security: the validation rule `distinct` scanned the whole list for each item, so its time grew with the square of the list length: 16 000 numbers took 15 s and 16 000 `items.*.id` 55 s, from a JSON body of under 100 KB. It now counts the list once per validation run (`ValidationContext.memo`, new and optional) and decides exactly as before. Affected releases: 1.0.0 and later.
