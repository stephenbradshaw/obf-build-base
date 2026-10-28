# obf-build-base

Compiler base image for obfuscated Rust builds: system toolchain, pinned
cross-compilation support (zig via `cargo-zigbuild`, MinGW, musl-tools,
`rcodesign` for Mach-O ad-hoc signing) and the obfuscating Rust/LLVM
toolchain releases from
[stephenbradshaw/llvm-project](https://github.com/stephenbradshaw/llvm-project).

Multi-arch (`linux/amd64`, `linux/arm64`), published to
`ghcr.io/stephenbradshaw/obf-build-base`.

## Usage

Downstream Dockerfiles pin the image by digest and add only their own
tail (project code, vendored dependencies, project-specific patch steps,
entrypoint):

```dockerfile
FROM ghcr.io/stephenbradshaw/obf-build-base@sha256:<digest>
```

Get the current digest with:

```sh
docker buildx imagetools inspect ghcr.io/stephenbradshaw/obf-build-base:latest \
    --format '{{json .Manifest.Digest}}'
```

## Pinned toolchain inputs

| Component          | Version            |
|--------------------|--------------------|
| Ubuntu base        | 24.04              |
| Rust (rustup)      | 1.99.1             |
| cargo-zigbuild/zig | 0.24.0             |
| rcodesign          | 0.29.0             |
| obf Rust/LLVM      | `OBF_TAG` (v23.1.3.10) |

apt package versions are not pinned and drift between base rebuilds; C/C++
dependencies compiled through zig are unaffected. Base rebuilds produce a
new digest — downstream projects re-pin and re-verify after rebasing.

## Environment

- `OBF_RUSTC` — the obfuscating `rustc` binary
- `OBF_CLANG` — the obfuscating `clang` (carries the
  `-sobf/-sub/-split/-bcf/-fla` C passes)
