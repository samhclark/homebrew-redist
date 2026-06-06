# homebrew-redist

[![Linux x86_64](https://github.com/samhclark/homebrew-redist/actions/workflows/tests.yml/badge.svg)](https://github.com/samhclark/homebrew-redist/actions/workflows/tests.yml)

Personal [Homebrew](https://brew.sh) tap that redistributes software not available in homebrew-core — either because the upstream ships no Homebrew formula at all, or because it only targets macOS and I want a Linux build too.

## Usage

```bash
brew install samhclark/redist/<formula>
```

`brew` auto-taps `samhclark/redist` on first install.

## Formulae

| Formula | Upstream | Platforms |
|---|---|---|
| `smolvm` | [smol-machines/smolvm](https://github.com/smol-machines/smolvm) | macOS arm64, Linux arm64, Linux x86_64 |

## Development

The current smolvm source-build status, reproduction steps, remaining binary
inputs, and GPU packaging notes are in
[docs/smolvm-source-build.md](docs/smolvm-source-build.md).
