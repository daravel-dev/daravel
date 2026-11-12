### Fixed

- `email:dns` (and any host read through `toAsciiHost`) refuses a domain that cannot fit before encoding it as punycode, which takes time quadratic in the distinct code points of a label: a label of 16 000 distinct characters took 4 s, and 100 000 minutes. A non-ASCII label of more than 59 code points, or a name of more than 253, cannot be a DNS name, as punycode keeps every code point; the result is the same as before for every name. This came in after 1.27.1 and was never released.
