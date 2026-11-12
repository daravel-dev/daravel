### Security

- Validation: `decimal`, `multiple_of`, `gt`, `gte`, `lt` and `lte` read a value as a number in time quadratic in its length, so one long string field could hold a worker isolate for minutes, within the default body limits. They now read it in linear time. The same values pass and fail as before. `size`, `min`, `max` and `between` were not affected. Affected releases: 1.22.0 and later.
