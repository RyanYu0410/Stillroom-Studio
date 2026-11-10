# Stillroom source

Native SwiftUI macOS executable. No third-party package dependencies. Apple-silicon release build included beside this folder. Open `Package.swift` in Xcode or use a Swift 5.9+ toolchain with a macOS 14+ SDK.

```
swift test
./build.sh
```

`build.sh` compiles the release binary, assembles the `.app`, copies Resources and signs it ad hoc. It does not notarize or install the app. The default destination is `../Stillroom Studio.app`.

The downloadable package stores demo resources once, inside the app. The build script and tests reuse those resources when `Source/Resources/Demo/Media` is absent. Keep the app and Source folder beside each other when rebuilding from that package.

The tests also verify backward compatibility, current motion direction, stored original-prompt provenance, source-frame bytes sent to the generator, take families, original preservation and replacement timing. Generation transport uses a deterministic fixture, without a real model job.

The tests cover split continuity, source ranges, reorder, invalid projects, relative paths, JSON and SRT round trips. The integration test uses the bundled original demo media, exports a short MP4 through the actual native engine, checks picture/audio/duration, and uses Vision to verify a burnt-in subtitle appears and disappears at its cue boundary.

## Structure

- `Project.swift`: portable document schema, validation, source resolution, timeline operations and SRT.
- `StudioStore.swift`: editing state, undo/redo, playback, import, portable saves, recovery and export.
- `MediaEngine.swift`: media inspection, thumbnails, measured audio envelopes, still-image video plates, composition and sound mixing.
- `CaptionCompositor.swift`: Core Image composition and Core Text subtitles for export.
- `LocalGeneration.swift`: loopback-only clients, source-frame capture, immutable regeneration jobs and take provenance.
- `LocalEngine.swift`: local engine discovery and a first-frame-only image-to-video workflow.
- `GenerationProgress.swift`: observed job stages, queue-aware elapsed time and estimates from compatible successful engine history.
- `GenerationProgressView.swift`: animated filmstrip progress with reduced-motion and accessibility support.
- `ShotCraft.swift`: shot plans, review ranges, reference provenance and native frame/motion sampling.
- `LocalReference.swift`: installed local image-model discovery, instruction edits and separate reference candidates.
- `ShotStudioView.swift`: Direct, Reference and Review & select tabs.
- `RegenerationUI.swift`: anchored clip prompt, take comparison and persisted disclosure sections.
- `StudioUI.swift`: library, viewer, inspector, timeline, captions, story and creation panel.
- `StillroomApp.swift`: app lifecycle, commands, file opening and transport keys.
- `Resources/Demo`: original project references, source takes, Blender clips and AAC sound stems. Large model weights are not included.

Runtime files are stored under `~/Library/Application Support/Stillroom/` and `~/Library/Caches/Stillroom/`. Portable user projects use `.stillroom` packages with `project.json` and `Media/`.

The code uses Apple frameworks. MLX-Serve source was consulted as a design and API reference; none of its artwork, logo or implementation is included. Sources: https://github.com/ddalcu/mlx-serve and its `docs/app.md`, `docs/api.md`, and video-generation service documentation/source.

See the parent Read-Me for user instructions, tested scope and generation limitations.

## Edit Assistant and Blender assist (0.8)

`EditAssistant.swift` discovers installed local chat models, requests a schema-constrained timeline plan and validates each supported edit before a single undoable apply. `EditAssistantView.swift` displays the plan and protects against stale edits. `BlenderAssist.swift` runs a fixed photo-card scene template; model text is never executed. It packs textures, renders a frame sequence and encodes a tagged MP4. Tests cover timing preservation, atomic apply, stale plans, model protocol, invalid actions and an opt-in installed-Blender render.

## Storyboard (0.9)

`Storyboard.swift` adds portable cards and atomic frame-aligned assembly. `StoryboardPlanner.swift` requests local structured drafts requiring explicit adoption. `StoryboardView.swift` supports card editing, reorder, continuity references, local frame generation, motion takes and timeline assembly. Indicators use the same native composition path as exported subtitles. Narrative caption times are provisional until recorded audio is aligned.
