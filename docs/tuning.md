# Local headphone-tuning experiment

The app manages independent named profiles, each with one current EQ and a persistent comparison history. A/Current/B is always available. The graph only displays Current, including during candidate playback. All five preference choices require listening to both A and B with processing enabled in the current round. Voting immediately saves the recommendation as Current, returns playback to Current, and resets listening eligibility. Disabling processing or changing headphones also clears eligibility. There is no separate tuning mode or explicit adoption step.

History groups adjacent votes on the same local calendar day when the gap is at most 30 minutes. Undated older votes form an Earlier votes group. Rolling back before a vote or group removes it and every later vote, reconstructs the posterior from the retained evidence, restores the pending comparison, and returns playback to Current. New votes also checkpoint the random generator for exact future continuation; older votes restore the learned curve and uncertainty, but did not store historical random checkpoints. There is no redo. Playback itself never starts automatically.

Profiles are selected manually: an analog headphone jack cannot identify which IEM is attached. State lives in `~/Library/Application Support/LowShelf/profiles.json`. The legacy directory name is retained across the FineTune rebrand to preserve profiles and votes. Writes are atomic, invalid files are preserved, and the old bass-mode settings are no longer used. No audio is stored or uploaded.

## Search model

Each ear has nine independently adjustable filters (18 parameters total): a 40 Hz low shelf, seven bell filters at 80, 160, 315, 630, 1250, 2500, and 5000 Hz (Q=0.85), and a 10 kHz high shelf. Each gain is bounded to ±12 dB. This is an initial parameter family, not arbitrary-frequency surgical EQ.

We assume a listener has an unknown preferred response and tends to prefer the candidate with the smaller squared curve distance. Distance is measured on 96 logarithmically spaced frequencies from 20 Hz to 20 kHz. Each ear's mean dB level is removed, and the two ears contribute equally to distance. Broadband left/right volume balance is not a search parameter; this search learns tonal shape.

For candidate stereo responses A and B and target T, the preference for A depends on `mean((B-T)^2 - (A-T)^2)` over both ears. A five-category ordinal probit model assigns utility intervals: strongly B below −4, slightly B from −4 to −1, indistinguishable from −1 to +1, slightly A from +1 to +4, and strongly A above +4. Observation noise has standard deviation 1.5 in squared-dB utility units. An 8% uniform lapse mixture allows any answer, even when it disagrees with the current estimate. Strong means a larger perceived improvement, not certainty; indistinguishable is a noisy interval, not exact equality or a skipped vote. These thresholds are a modeling convention, not a measurement of the listener's discrimination threshold.

The target filter gains have a correlated Gaussian prior: neighboring bands tend to move together, with additional independent variance so more detailed shapes remain learnable. Left and right share a broad prior; a smaller, nonzero difference prior encourages similar curves until comparisons support asymmetry. Both shared and opposing-ear directions remain available throughout tuning. A local numerical Jacobian connects actual filter responses to gain parameters. Gaussian moment updates retain uncertainty. Every 20 new answers, the model revisits all observations once from the original prior, in a reproducibly shuffled order and with an updated local response model. This avoids permanently anchoring on unlucky early votes; it does not count the same observations multiple times in one posterior.

Candidate generation considers shared and opposing-ear cosine directions plus random stereo directions around the current recommendation. The comparison with the greatest approximate reduction in curve uncertainty is selected. A/B labels are randomized. Probes use a 2–3 dB RMS radius before parameter clipping and retain meaningful separation as the estimate improves, because comparisons between nearly identical candidates contain little information under fixed noise. The internal uncertainty is a model estimate, not measured error or a guarantee about the listener.

## Audio behavior

The plotted filter coefficients are the coefficients sent to the C processor. Processing uses double precision, separate coefficients and histories per channel, and a 50 ms crossfade between two filter banks. Control updates use atomic snapshots; the callback never allocates, locks, or performs file I/O.

Profiles are attenuated to put the highest combined frequency response below 0 dB, then given another 6 dB of headroom. During a comparison, both ears of Current/A/B curves share a common mean log-frequency response level and all retain that margin. Attenuation is computed separately for each ear against one common ceiling across all candidates; neither preamp boosts. This preserves equal centered channel levels without discarding different tonal corrections. This is approximate level balancing, not measured perceptual loudness matching. There is no makeup gain, compressor, or limiter. A fixed margin is not a proof against every possible waveform peak; the existing peak/fault monitoring remains active.

Use a repeated passage in your music player and hold playback volume steady. The app does not capture or replay a loop, and differences in the music or its spectrum can bias choices. Repeat across recordings and sessions before treating a profile as settled.

## Validation

Run `./scripts/check.sh` for all checks, or:

```sh
swift run -c release -Xswiftc -warnings-as-errors TuningChecks /tmp/lowshelf-validation
python3 scripts/plot-convergence.py /tmp/lowshelf-validation
```

The Swift tests have no third-party dependencies and play no audio. Plotting optionally requires matplotlib and numpy.

The legacy binary suite remains as regression coverage. The stereo five-choice suite runs with `swift run -c release -Xswiftc -warnings-as-errors StereoTuningChecks /tmp/lowshelf-stereo-validation`.

The synthetic listener scores actual nonlinear filter-response graphs, adds independent Gaussian noise to each candidate's squared error, and randomly reverses some votes. The optimizer never receives the target, distances, noise draws, or gradient. The production app and test executable import the same `TuningCore` implementation.

Eight named targets include flat, warm, V-shaped, presence, dark, a local notch, alternating bands, and strong bass. There are 12 independent seeds per target. Ordinary listeners have per-candidate noise σ=0.9 and 4% reversals; unreliable listeners have σ=1.8 and 10% reversals and answer tentatively. Pass criteria are per-run RMS error below 0.65 dB after 240 ordinary comparisons and below 1 dB after 400 unreliable comparisons. Twelve additional random curves use unseen seeds. Twelve long runs must improve their mean error by at least half from 240 to 3,000 comparisons, and each finish below 0.15 dB.

Additional checks cover confidence weighting, ties versus skips, undo, exact resume, legacy saved-curve isolation, corrupt-file preservation, actual DSP gain at four sample rates, stereo independence, and rapid filter changes. Reports include every iteration's error and model uncertainty plus all final target/matched curves.

These are finite empirical tests, not a proof of arbitrary convergence. The model is approximate and assumes stable, roughly distance-based preferences. Curves outside the nine-filter family, inaudible distinctions, absent frequency content, and changing or systematically biased preferences can prevent an exact match. More votes do not overcome those limitations.

## Legacy shared-curve results

All 216 simulated sessions passed (96 ordinary, 96 unreliable, 12 random holdouts, 12 extended runs).

| Listener / budget | Mean RMS error | Worst RMS error |
| --- | ---: | ---: |
| Ordinary, 100 comparisons | 0.354 dB | 0.592 dB |
| Ordinary, 240 comparisons | 0.218 dB | 0.372 dB |
| Unreliable, 400 comparisons | 0.308 dB | 0.477 dB |
| Extended, 3,000 comparisons | 0.063 dB | 0.080 dB |

Development exposed an early-vote anchoring failure (one unreliable run remained 1.12 dB away). Periodic full-history refitting fixed that failure without weakening the pass criteria. A local response Jacobian removes the fixed one-dB filter-basis approximation from the observation model. The one-dB basis remains only a query-selection approximation. A skip at a refit boundary is explicitly tested to leave the estimate unchanged.

These errors describe frequency-response shape, not perceived quality, and remove overall volume. The long-run improvement is evidence that refinement continues; it is not an assertion that every listener or curve converges arbitrarily closely.

## Profile migration

Version 1 files load without any disk writes. Saved curves are copied identically to both ears. The old shared posterior becomes the shared component of the new prior; fresh uncertainty is added only for left/right differences. The pending comparison, profile identity, old full history, learned recommendation, and random-generator continuation are preserved. New five-choice answers are stored separately so old confidence votes are not reinterpreted as strength ratings. Rollback can cross the migration boundary by replaying the retained original votes, then reconstructing the stereo prior. The first save writes a byte-for-byte, uniquely named `profiles-v1-<UUID>.json` backup before atomically writing version 3. Version 2 files similarly receive a `profiles-v2-<UUID>.json` backup on first save. Existing answers decode without invented timestamps; their original ratings and confidence values remain intact. The old `saved` field remains as a compatibility field synchronized to Current on preparation, voting, and rollback. Corrupt files are preserved.

The two ears are judged together during ordinary stereo playback, not isolated or alternately muted. Music with unequal channel content can bias learning; repeated passages and varied recordings help. The simulations assume both ears influence the response-distance oracle. They cannot establish what a real listener can hear, or recover corrections for frequencies absent from the audio.

## Stereo five-choice results

All 118 stereo sessions passed: 48 ordinary, 48 unreliable, 12 unseen random stereo targets, 6 extended runs, and 4 continuations from learned legacy profiles. Ordinary cases use 400 votes, per-candidate noise σ=0.9, and 4% reversals. Unreliable cases use 600 votes, σ=1.8, 10% reversals, and wider indifference/strong-preference thresholds than the optimizer assumes. Holdouts use narrower thresholds. Each ear is checked independently (limits 0.65 dB ordinary/holdout/migrated and 1 dB unreliable), so one accurate ear cannot conceal a poor result in the other.

| Listener / budget | Mean of worse-ear RMS error | Worst single-ear RMS error |
| --- | ---: | ---: |
| Ordinary, 400 comparisons | 0.202 dB | 0.296 dB |
| Unreliable, 600 comparisons | 0.387 dB | 0.578 dB |

Six extended sessions improved their mean combined-ear RMS error from 0.216 dB at 400 votes to 0.101 dB at 2,000. Every ear finished below 0.2 dB. Four migrated sessions learned new asymmetric corrections within the same 0.65 dB bound after 400 new comparisons.

Development exposed excessive shrinkage of fine ear differences. Raising the independent difference-prior variance from 0.5 to 1.5 made those corrections easier to learn while retaining a smaller difference prior than shared prior. Increasing the minimum probe radius from 1.5 to 2 dB improved late-stage information under noise without weakening the accuracy criteria. Reports retain each iteration's left/right error and model uncertainty.

Additional checks verify all five rating categories, soft indifference, undo across refitting, deterministic resume, version-1 migration and byte-identical backup, continued learning after migration, separate audio responses within 0.02 dB at four sample rates, zero channel crosstalk, common centered playback level, and rapid changes. The interface was exercised in a separate app identity using a copy of the live profile; no audio route was started. The original profile file and running app were left intact.


## Continuous tuning and history validation

`swift run -c release -Xswiftc -warnings-as-errors HistoryChecks` checks A/Current/B eligibility, exact posterior and random-state restoration across refits, rollback into original shared-ear history, version-2 migration with a byte-identical backup, immediate Current adoption, persistence across relaunch, and grouping at idle/day boundaries. No audio is played by these checks.
