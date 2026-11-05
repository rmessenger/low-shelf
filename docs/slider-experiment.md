# Online slider experiment

This is a local experiment; the original cumulative-vote algorithm is still available through the Tuning menu. The source checkpoint before this experiment is commit `0aa7f1af162061594b4a4f44b6ca9c89cca235ea`.

## Interaction and storage

Current is the exact center of the slider. Each half interpolates filter gains between Current and its endpoint, preserving the same stable, double-precision filters and 50 ms transition used by the original app. The graph remains on Current during preview. Use this sound adopts the auditioned curve exactly, persists it, resets the slider to center, and generates a new comparison. Choosing the center leaves the curve unchanged and advances to a new adjustment. Preview positions are temporary; committed choices survive relaunch. No vote history influences the slider search, and there is no slider undo.

The experiment uses `~/Library/Application Support/LowShelf/profiles-slider.json`. The original method continues using `profiles.json`. Initial import preserves both headphone IDs, names, selection, and latest learned left/right curves; it removes the old inference state from the new file. First import also writes an exact copy of `profiles.json` under `Backups/BeforeSlider-<UUID>/`. The original file stays intact. Existing experiment data is resumed rather than imported again, and invalid experiment files are preserved rather than overwritten.

Switch back through Tuning → Original A/B voting. This loads the original profiles and history, without applying slider changes to them. Returning to Slider experiment resumes its separate curves. Profile additions, renames, and deletions are also independent after initial import.

## Fixed-state algorithm

The search stores the current 18 filter gains, a pending comparison, a random generator, a shuffled list of 34 direction indices, its cursor, and a choice counter. State size does not grow with judgment history except for the digits in the counter. There is no posterior confidence, history replay, learning-rate decay, or running average of accepted curves.

Each shuffle visits 16 broad response directions and 18 individual-ear band directions. The broad directions come from smooth shared/opposing-ear cosine patterns, orthogonalized using the response derivative at flat EQ. Two nearly flat directions are omitted from that set because they require disproportionately large gain changes; individual bands retain coverage of those degrees of freedom. The individual-band directions also prevent clipping from trapping the search along the broader directions. Labels are randomized independently of the adjustment direction.

Endpoints use a nominal 2.5 dB RMS response displacement on the linearized model. Actual nonlinear filters and the ±12 dB gain bounds can change that distance. Directions whose nearer endpoint is less than 0.75 dB RMS from Current are skipped; after a bounded full search the widest available pair is used. Both endpoints exceeded the floor in all validation trials, including fully saturated gain vectors. This is a response-distance proxy, not a guarantee of audibility for every person or recording. Exploration never shrinks with the number of choices.

The slider interpolates between Current and each clipped endpoint separately. This keeps the midpoint exact even when the two feasible endpoint distances differ. The accepted displacement is entirely driven by the slider position. A large choice immediately makes a large change, irrespective of how long the profile has been used.

Playback level is centered across ears and slider positions using a per-round sampled level plan. The selected curve is checked independently before playback, retaining at least the existing 6 dB frequency-response headroom and never adding positive preamp gain. The numerical check can conservatively reduce gain if an intermediate curve exceeds the sampled envelope. Across all tested positions the centered level stayed constant. These are frequency-response checks, not a mathematical peak bound for every possible waveform.

## What can be proved

In an ideal linear response model, write the error from a fixed target as `e` and a unit search direction as `u`. An exact line choice removes the error component along that direction:

`e_next = e - <e,u> u`.

Therefore squared error decreases by `<e,u>²`. With an orthonormal spanning set and unrestricted exact line choices, one full sweep reaches the target. More generally, repeated exact coordinate minimization of a positive-definite quadratic converges. This explains the method, but is not a global proof for nonlinear filters, clipping, skipped directions, or real listeners.

With additive zero-mean selection error `eta` in response units, the update becomes:

`e_next = e - <e,u> u + eta u`.

For independent uniform choices from `d` orthonormal directions, the idealized expectation is:

`E[||e_next||² | e] = (1 - 1/d) ||e||² + Var(eta)`.

This contracts toward a noise floor of `d * Var(eta)` in squared response error. Persistent nonzero choice noise prevents convergence arbitrarily close to zero while every choice is adopted directly and exploration stays wide. Reducing that floor would require more precise judgments, averaging repeated judgments, or damping accepted movement; those would change the requested behavior.

When the target changes, the same relation applies to the error relative to the new target. There is no accumulated confidence to overcome. The production algorithm is more complicated than this idealization, so changed-target simulations are also required.

“Arbitrary target” here means a response within the existing nine-filter-per-ear family and gain bounds. Unrepresentable curves, changing targets during a comparison, biased judgments, or inaudible frequencies cannot be covered by a convergence guarantee.

## Validation

Run:

```sh
swift run -c release -Xswiftc -warnings-as-errors SliderChecks /tmp/finetune-slider-validation
```

The oracle minimizes squared distance between actual nonlinear response curves, searching each slider half independently, then adds Gaussian position noise and clips to the slider range. The production optimizer receives only the chosen position. It does not see the target, distances, or the oracle's optimum.

Five named targets cover flat, warmth, different left/right tilts, strong bass with a unilateral notch, and fine alternating corrections. Each noisy scenario uses six random seeds per target. Twelve additional tests use unrelated random starting curves and targets. A position standard deviation of 0.025 is 1.25% of the full slider width; 0.06 is 3%. The heavier-noise scenario also adds occasional larger errors: a 5% chance of an extra Gaussian perturbation with standard deviation 0.2.

For noisy trials, the reported number is the mean of the worse ear's RMS error over the final 68 choices of a 408-choice run. The maximum column is the worst trial's late mean, not the largest instantaneous excursion. This avoids presenting one lucky final choice as convergence.

| Scenario | Trials | Mean error | Worst trial |
| --- | ---: | ---: | ---: |
| Ordinary noise | 30 | 0.292 dB | 0.384 dB |
| Heavier noise plus occasional slips | 30 | 0.687 dB | 0.857 dB |
| Unseen random targets and starting curves | 12 | 0.288 dB | 0.393 dB |
| New target after 1,020 earlier choices | 6 | 0.285 dB | 0.325 dB |
| Noiseless refinement, final error after 2,040 choices | 4 | 0.025 dB | 0.042 dB |

All acceptance thresholds were applied per trial. Ordinary, holdout, and shifted-target late means had to be below 0.65 dB; heavier-noise late means below 1.5 dB. Noiseless final error had to be below 0.15 dB and improve beyond the initial two sweeps. Changed-target trials also had to more than halve their initial error against the new target.

Additional checks cover exact adoption of the auditioned curve, center/endpoints, range clamping, nonfinite inputs, deterministic resume, bounded state size, endpoint separation at boundaries, preservation of both original profiles, byte-identical backups, independent file persistence, corrupt-file preservation, and level matching/headroom throughout the slider at four sample rates. Maximum observed per-position level calculation was 1.65 ms on the development Mac. The original DSP, hotkey, history, and cumulative-optimizer regression suites also passed.

Initial testing found that broad directions alone stalled near the gain boundaries. Adding individual-band directions restored refinement. Reordering the broad basis to prioritize tonal contrasts and omitting nearly flat basis directions reduced noise sensitivity. The final production code and all simulation trials use the same implementation.

These results demonstrate finite empirical accuracy and recovery under the stated noise models; they do not prove global convergence for every target or human listener. A slider choice also provides more information than a five-way vote and can take longer, so iteration counts are not a direct measure of comparative listening effort.
