# CI publish plan

- Remote baseline: `qq6688000/OpenMinisBuild`, branch `workbuddy-1.15`, public HEAD `e5239f9f3ad4bc0d9810185b05673aaa13d88c47`, tree `2cd61b35c8715cb8481ab2695c5d5cd2b6b83c0b`. The local checkout preserves the real commit parent and gitlinks `deps/ish=0fd17a135e78b7a0cf08a4f5831217bbb76ed22f` and `deps/proot=8b31a69345730692f2f49a88694fdcaec78b2031`.
- Local branch: `apelin-integration`; 151 changed files. Run `git rev-parse apelin-integration` for the immutable local commit ID; the external delivery copy of this plan records it after creation (a commit cannot include its own hash). Its parent is `e5239f9f3ad4bc0d9810185b05673aaa13d88c47`.
- Checkout was reconstructed from SHA-verified Git objects and the exact archive after a 60-second Git fetch timeout. The true baseline is an explicit shallow boundary; its original parent header remains intact. No fabricated ancestry or baseline snapshot commit remains.
- Scope: cumulative Apelin integration, validation harnesses and fixtures, native bridge checks, workflow dispatch/build alignment, Swift settings UI/model/templates, and review documentation. Generated dependency outputs, archives, caches, and submodule contents are excluded.

## Runtime expectations

GitHub Actions uses `macos-15`, selects `/Applications/Xcode_26.2.app`, and checks the iPhoneOS SDK is 26.2 before compiling. This is required because the project has iOS 26.2 target/API references; the main app's supported runtime floor remains iOS 16 where configured. The early Swift and native harnesses run immediately after Xcode selection and before dependency compilation. They fail the job on compiler or validation failure. The authoritative Codemagic dependency build, SwiftPM retry, native dependency cache/build, archive provisioning, extension signing, toolchain archive checks, and unsigned IPA packaging are retained/aligned. GitHub `workflow_dispatch` remains enabled; the branch push trigger remains limited to `workbuddy-1.15` until a later deliberate workflow policy change.

The public upload is the GitHub Actions artifact `Minis-unsigned-ipa`, retained 30 days, containing `Minis-unsigned.ipa`; Codemagic also publishes `Minis-unsigned.ipa` and build logs as configured. No source archive, credentials, or generated dependency tree is uploaded by this change.

## Validation and limits

Passed locally: provenance/model/template validation (121 files, 16 generated projects), schema fixtures, Python/static native checks, shell syntax checks, Git whitespace checks, and actual arm64 iOS ObjC cross compile/link/private-XPC checks. Swift/Xcode, full app/bridge compile, native dependency build, SwiftPM resolution, package creation, device installation, XPC authentication, and runtime acceptance are unrun here because this host is Alpine iSH without macOS/Xcode. No remote CI was invoked.

## Publication and rollback

After separate review approval, from this checkout run `git push origin apelin-integration:refs/heads/apelin-integration`, then separately approve/run `gh workflow run ipa.yml --repo qq6688000/OpenMinisBuild --ref apelin-integration`. Recheck the remote workbuddy HEAD and branch-name availability first; do not force-push. Existing default-branch `ipa.yml` contains workflow_dispatch, so the branch ref is dispatchable after publication. Push to this new branch does not match the current workbuddy-only push trigger. Git transport may still time out; transfer the commit to a functioning checkout before publishing if needed. Neither command has been executed.

Publishing the branch makes all 151 changed source/config/documentation files publicly visible in GitHub history. A CI run also exposes logs and the IPA artifact (no release is created), with a 240-minute job timeout and roughly 30–60+ minutes expected for a cold dependency build; actual duration is unmeasured. Early harnesses compile on host macOS 12.0 targets, run real fixtures with Bundle.main resources, and need only Xcode, not Homebrew/native dependencies. Native iOS typecheck uses arm64 iOS 16.0. The App floor is 16.0, widget 16.2, tests 26.2; SDK 26.2 does not raise those deployment floors.

Rollback: before merge, delete only the new remote branch (`git push origin --delete apelin-integration`) and cancel any separately approved run; after merge, revert the integration commit through review. Deleting a branch does not remove already published logs/artifacts; delete those separately if required. The remote workbuddy base remains unchanged by branch publication.
