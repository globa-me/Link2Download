# Contributing to Link2Download

Thanks for helping improve Link2Download.

## Before you start

- Search existing issues and pull requests for related work.
- Keep macOS changes in `Sources/`, `Resources/` and `scripts/`.
- Keep Windows-specific code under `windows/`.
- Do not commit downloaded runtime binaries or generated build output.

## Local checks

For macOS logic changes, run:

```bash
./scripts/test_retry_history.sh
./scripts/test_runtime_process.sh
```

For Windows changes, run on Windows with the .NET 8 SDK:

```powershell
dotnet test .\windows\Link2Download.Windows.sln
```

Changes to runtime integration should also follow the relevant smoke-test instructions in the main README.

## Pull requests

Describe the user-visible behavior, platforms affected, checks performed and any remaining limitations. Keep unrelated refactors out of the same pull request. Never include cookies, signed URLs, credentials or unredacted diagnostics.

By contributing, you confirm that you have the right to submit your work. The repository does not currently declare an open-source license; contributions do not change that status.
