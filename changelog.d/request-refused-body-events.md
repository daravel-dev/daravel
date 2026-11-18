### Fixed

- A body refused while it was read (a chunked body over `maxBodyBytes`) no longer logs `Uncaught asynchronous error … Cannot add event after closing` when the server releases the rest of it after its answer (a streamed `413`, an answer that fails to write, a client that goes away or ends its body midway): what the rest still reports is dropped, as its data already was.
