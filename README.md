# homebrew-redist

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
