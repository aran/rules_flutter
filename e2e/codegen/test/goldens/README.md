# Golden fixtures for the `flutter_test` comparator e2e

`stand_in.png` is a 1×1 transparent PNG. It is **not** a rendered golden and
must never be regenerated with `--update-goldens`.

Its job is to be a real, declared golden file that is *guaranteed* not to match
whatever the test renders, on every host. That makes it the discriminator for
the two failures a golden comparison can produce:

- declared in `data` → the comparator finds it and reports a **pixel
  mismatch**;
- present on disk but *not* declared → the comparator reports a
  **non-existent file**, because a sandboxed test sees only its declared inputs.

`golden_test.dart` and `golden_undeclared_test.dart` assert exactly that
difference. A golden that actually matched this host's rendering would be a
machine-specific artifact — font rasterisation and antialiasing differ across
operating systems — so no such PNG is committed here, and the suite makes no
cross-OS pixel-identity claim.
