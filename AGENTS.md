# Local development workflow

- Keep changes local unless the user asks to commit or push.
- After each app iteration, build and verify `dist/FineTune.app` with `./scripts/build.sh`.
- Leave the latest build running. Gracefully quit any older running LowShelf or FineTune instance before launching the new build; do not restart an instance that is already current.
- Use the available native app controls to quit and launch the app. Verify that the new app is running.
- Keep only the latest runnable app bundle; remove obsolete local app bundles and distribution archives created for this project. Preserve source, validation reports, and user data.
- Preserve the bundle identifier and the existing `~/Library/Application Support/LowShelf/profiles.json` storage location across rebrands and builds.
