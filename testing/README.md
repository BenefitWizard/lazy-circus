# lazy-circus-testing

Internal testing toolkit for the [Lazy Circus](https://github.com/BenefitWizard/lazy-circus)
framework: mocks, test performers, and scenario helpers. All modules live under the
`LazyCircus.Testing.*` namespace.

## Posture: internal tool with public hygiene

- **No semver.** This package is not consumed standalone; its version number is not an
  API promise.
- **Breaking changes are allowed at any time**, coordinated with the packages that pin
  it inside the monorepo (pin coordination: bump consumers in the same commit).
- **Haddock is mandatory on seam contracts.** Every exported function or type that
  other packages touch must carry a Haddock comment, with `PRE-CONTRACT` /
  `POST-CONTRACT` lines where the type system cannot express the invariant.
