# The Penlock cell model

`cell-reference.onnx` is the project-authored 29-symbol classifier that reads
each cell of a Penlock share strip. It is distributed under MIT OR Apache-2.0,
like the project's own code, and it lives beside `penlock-scan` because that is
the crate that loads it. The BIP39 word pipeline's models are in the
repository's top-level `models/`; neither pipeline embeds or exposes the
other's.

The Android example copies this file and the word pipeline's models into its
APK assets. It never downloads replacements.
