# Scanner public API inventory

This records the reachable *default-feature* scanner API, not just what the
`bitcoin-vision` facade chooses to re-export. `scan` below is the shared
`bitcoin-vision-core` retained record. `research` is deliberately not a
facade default. An output type may be reached through a scan result without
making its implementation stage a module in the public namespace.

| Crate | Existing route | Destination |
| --- | --- | --- |
| Both | `Scanner`, model bytes, `ScanOptions`, `Scan`, `ScanResult`, `ScanError`, `scan` | Default scan contract |
| Both | `image`, `imageproc` crate re-exports | Removed; consumers declare their own dependencies |
| Penlock | `bare`, `cells`, `locate`, `marks`, `model`, `template`, `title` and all of their public functions, constructors and methods | `research` only; private in normal builds |
| Penlock | `sheet` worksheet/cut/render functions and types | `print` or `research`; private in normal builds |
| Penlock | `scanner` module and `from_model` | Module private; model injection `research` only |
| Penlock | `ScannedShare`, `Identity`, result/document/observation/cell, `Phase`, `Strips`, `StripRegion` | Default result/progress data; location and cell geometry exposed as data rather than locator/cutter objects |
| Penlock | `Homography`, `Rect`, `Font`, `Jitter`, `CellImage`, `WORDS`, `print` convenience root re-exports | Removed from scanner root; forms/print or research own these |
| Words | `detect`, `fragments`, `hybrid`, `numbering`, `page_frame`, `recogniser`, `sources`, `words`, `wordsheet` and their stage functions/methods | Private default; `research` for probes; only input/output data stays on scan contract |
| Words | `dot_grid`, `extent`, `inference_limit`, `joins`, `layout`, `phrase`, `region`, `split` | Already private default or experiment/research; keep that boundary |
| Words | `boxes`, `progress`, `timing`, `vocabulary`, `output` | Box/progress/result data in scan contract; stage callbacks private; timing profile-only; vocabulary private |
| Words | `Reader`, `PageLayout`, `Frame`, `WordBox`, `JoinRead`, `JoinTrial`, phrase evidence/type re-exports | Reach saved evidence through result projection, not stage root exports; `research` retains the native types |
| Words | `Word` root re-export, `homography`/`runtime` re-exports | Vocabulary only through result data or research; core utilities through `bitcoin-vision-core`, not scanner root |
| Words | `Scanner::from_models`, `Scanner::recogniser` | Model construction via `Scanner::new`; stage injection research-only; profile via opt-in scanner method |

The Penlock rows above are implemented. BIP39's old stage data is still used
by the Android review/diagnostic adapter; its privacy rows are the remaining
part of this plan, not a claim that the facade alone has hidden them.
