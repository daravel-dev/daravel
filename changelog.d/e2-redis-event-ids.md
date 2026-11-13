### Fixed

- `RedisEventStream.listen` (and `since(request)`) treats a `Last-Event-ID` that is no stream id (`abc`, a part over 64 bits) as no header instead of letting the next live event throw out of the stream's shared listener, compares stream ids without `int.parse` (`RedisEventStream.isStreamId`, `streamIdAfter`; a full 64-bit id from Redis included), and hands any error of an event to its own listener; since 1.12.0.
