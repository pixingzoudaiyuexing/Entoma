# macOS13 minimum-version delta

Owner's2026-10-17 decision sets Entoma's first public test version to macOS13.0+.
macOS10.15–12 support is intentionally removed; no legacy proxy Helper fallback
will be developed. This is an approved product compatibility change, not merge
or release authorization.

## Narrow review scope

Review only the delta after PR #9's accepted CONDITIONAL candidate
`3fb9688f512e5007093b463d36f7900a5bf5d5d7`. The exact new HEAD, CI run, installer
SHA-256 and artifact inspection report are supplied by the PR/delivery evidence.
PR #9 remains stacked on PR #8 HEAD
`861ac88bc592fd635ab1172ef5e76f3b9bed7c90`; no rebase or implicit temporary-session
merge is part of this task. The existing one-click and Helper runtime is unchanged.

Xcode Debug/Profile/Release, Podfile and both owned podspecs require13.0.
Post-install assigns13.0 to actual CocoaPods build targets without modifying
third-party source specifications. Info.plist continues to derive
LSMinimumSystemVersion from the deployment target. Helper compilation already
targets13.0 for arm64 and x86_64 and keeps its signature/permission policy.

## Actual artifact checks

`tool/verify_macos_minimum.py` inspects built files without executing payloads:

- App Info.plist and GUI Mach-O slices require exactly13.0.
- Owned proxy/window_ext native framework slices require13.0.
- Flutter/AOT/Go runtime slices must have minimum requirements no newer than13.0
  and cover the GUI's architectures. A toolchain runtime supporting older systems
  does not lower the containing application's13.0 requirement. No vendor binary
  or Go linker is patched to manufacture a matching version string.
- Every embedded Mach-O is scanned for a minimum no newer than13.0 and coverage
  of the GUI's actual architectures, including other plugin/vendor frameworks.
- The product PKG Distribution must contain one open-ended13.0 OS range and
  exactly the GUI's actual architectures (arm64/x86_64 for the universal CI
  product). Its extracted App is re-inspected and hashes must match the verified
  build. A local arm64-only package must declare only arm64. CI uploads the
  resulting JSON with the installers.
- The report records checkout SHA and any tracked build-time diff (excluding
  submodules). Generated integration changes must be examined explicitly; a
  successful build alone does not prove a pristine runtime source tree.
- A separately supplied compile-only Helper can be inspected for both13.0
  architecture slices; this does not register or install a privileged service.

The workflow retains the component receipt and wraps it with productbuild using
`packaging/macos/requirements.plist`. This creates an explicit Installer OS gate;
the previous bare component PKG did not declare that gate. Apple documents
[Installer OS version ranges](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html),
and the installed productbuild manual defines the requirements plist's `os` key.
Static metadata/Installer requirements are not an actual macOS12 rejection test
or a macOS13 runtime acceptance claim.

## Review and release gates

The upstream PR #8/#9 CONDITIONAL decisions are retained as supplied by Project
+ Product Manager. The original Independent Reviewer must assess this exact new
delta; until their supplemental verdict is received/accepted its status is
PENDING. Embedded checks do not substitute for that verdict. No full review of
unchanged one-click/Helper code is requested.

The approved minimum-version decision closes the old-system support-policy gap
once the code/artifact checks pass. It does not close:

- Windows new one-click physical acceptance after vendor maintenance.
- The missing Developer ID Application identity and signed Helper embedding.
- Real installation/approval, signed XPC, repeated-toggle authorization behavior,
  selected-node HTTPS forwarding and network restoration acceptance.
- Final release signing/notarization, financial server idempotency/reconciliation
  and corresponding-source distribution obligations.

Both PRs remain Draft. No main merge, Release, production deployment, unsigned
privileged installation, authdb or sudoers change is authorized here. Older
reports remain historical evidence and are not rewritten as macOS13 acceptance.
