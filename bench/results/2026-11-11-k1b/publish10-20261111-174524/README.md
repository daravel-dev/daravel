# publish × 1 and × 8, 10 rounds alternating (after the merge of K1 + K1b)

`publish` alone, one and eight senders, 20 s per point, ten rounds with the order alternating, each run started once the 1-minute load was below 2 (`publish10.sh`). The two builds:
- **before:** main before #239 (bc30f4f7), with the K1b bench file adapted to its API by one `sed` (it drops `bulkWindow:`/`bulkBuffer:` and replaces the two default constants by 16 and 1024);
- **after:** main after #239 (ee408f3b).

Result (`summary.txt`): × 1 +0.8 % and × 8 −0.5 % (median after against before), with the ranges overlapping fully. The −8 % of the 5-round final series (`final/`) does not come back over 10 alternating rounds. The absolute numbers of this series are **not for quoting**: they are about a third below the morning's, most likely because another session worked on the machine meanwhile; both builds ran alternately under the same conditions, so the comparison holds.
