### Fixed

- A malformed `Last-Event-ID` header (`abc`, a part over 64 bits) is read as no header by `RedisEventStream.listen` and `since(request)`: the connection gets live events, where it got none and each event logged an uncaught error for it. Stream ids are compared without `int.parse` (`RedisEventStream.isStreamId`, `streamIdAfter`; a full 64-bit id from Redis included), and an event's error goes to its own listener; since 1.12.0.
