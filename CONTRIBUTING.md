# Adding an interaction

1. Create a branch, for example `kagan/ripple-interaction` (fork contributors may use their own prefix).
2. Run `python3 scripts/new-experiment.py Ripple` from anywhere in the checkout.
3. Replace `Experiments/Ripple/Sources/RippleApp.swift` with your experiment. Keep it self-contained.
4. Add resources to the Xcode target, not just the filesystem. Use local assets; do not leave temporary export URLs in source.
5. Complete the experiment README using the template. Add a small preview to `Media/` and an entry to the main README.
6. Build with `./scripts/build.sh Ripple`. Try the interaction on its required device. Document any unverified behavior.
7. Review the diff for signing identities, private paths, recordings, secrets, and build output before opening a pull request.

Prefer native Apple frameworks and no external dependencies. If a dependency is necessary, document its version and license. Provide appropriate accessibility labels, sufficient hit areas, and a Reduce Motion alternative.

Do not change existing interactions’ behavior as part of adding a new one. Keep fixes separate and include a short before/after explanation.

## Local checks

`./scripts/check-bubblegum.sh` runs the imported Bubblegum checks, including sensor-aware sway assertions. `./scripts/build.sh NAME` builds just the requested experiment for the simulator. No hosted CI workflow runs automatically in this starter collection.

Physical-device builds require your own Apple development team and bundle identifier. Do not commit provisioning profiles, credentials, or user-specific Xcode state.

## Licensing contributions

Submit only work you have the right to contribute. Your original contributions must be offered under this repository’s [license](LICENSE), with separately licensed material identified in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). You retain your copyright. A permission from Kağan to omit the project credit does not waive another right holder’s separate rights or asset conditions.
