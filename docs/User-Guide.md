# Stillroom Studio

A native Mac workspace for films made from image references, local AI motion, small Blender inserts and carefully edited sound.

## Open the app

Open **Stillroom Studio.app**. You can also drag it into Applications. The first session opens an editable scene study based on *The Missing Moment*. Press **Space** to play.

This is a working **0.9 development build for Apple silicon**, built for macOS 14 or later and tested on macOS 26.6.2. It is signed locally, not notarized for public distribution. macOS may ask you to approve this development app in Privacy & Security when opening a downloaded copy on another Mac.

The editor itself needs no account, subscription, Python installation or external rendering tool. It uses SwiftUI, AVFoundation and Core Image. AI generation reuses the installed local LTX environment and model files. Stillroom now discovers the production engine, starts it when needed and prepares its own workflow. The model weights are not duplicated inside this small app download.

## Regenerate a selected clip

Select a picture shot in the timeline. The **Regenerate clip** prompt box sits below the viewer. Describe the change you want, then press **Regenerate** or **⌘Return**. With **Automatic** selected, Stillroom finds the installed video engine, starts it if needed, prepares the reference and builds the workflow. No server address, workflow JSON or node ID is needed for the normal flow.

Regeneration uses the original reference image by default, or a reference you explicitly choose in Shot Studio. For a video without an existing reference, Stillroom captures the actual source frame at the shot’s source in point. The original frame establishes appearance; your current prompt supplies action and camera movement. The old prompt stays in the take’s recipe for provenance, but is not repeated into the generation prompt: older directions such as “locked camera” or “small movements only” can conflict with the new action.

Set **Length** beside the quality picker to choose **1–10 seconds**. Length is independent of picture quality. The model uses discrete frame counts at 24 fps, so a five-second request produces approximately 5.04 seconds. Hover over Length to see the nearest supported duration.

The new video becomes a separate take. Use the **Original** button and **Compare take** picker to review versions. Choosing a video take or pressing **Play take · 1×** starts actual playback at normal speed; pressing Play again after the end restarts it. **Use take** changes only the selected shot and preserves its timeline duration, so captions and separate sound layers keep their positions. The clock menu beside **Use take** also offers **Use generated length**, which plays the new source at normal speed and changes this shot’s length. Later picture shots move with the sequential edit; caption and sound positions stay fixed, so review their timing after this choice. The original source remains available, and Undo reverses the replacement. When fitting a take to the existing shot, a take too short or long for the supported speed range is rejected without changing the edit. The clock menu can instead use its actual generated length at **1×**. For example, fitting a 3.38-second take into a 13.92-second shot slows it to 0.24×; the take controls show this when fitting would substantially slow the motion. Review at 1× before judging the model’s movement. You can restore an original still image too.

Each generated source stores its parent, reference, prompt and recipe, including seed and requested change, inside the portable project. A new seed gives each regeneration a fresh variation. Enable **Keep seed** in creation settings for controlled prompt comparisons. The recipe records the exact seed used.

This is regeneration from an anchored image, rather than a video-to-video transformation that preserves every original motion. Review continuity and performance before accepting a take. When a new source replaces a shot, sound that was embedded only in the old video does not transfer automatically. Separate voice, room, foley and score layers remain untouched.

## Make deliberate shots in Shot Studio

Select a timeline shot and choose **Shot Studio** beside Regenerate clip. This adds the process used to make the example film: compose a strong starting frame, direct one action, generate a short take, review the result and choose its usable range.

**Direct** holds the story beat, visible action, camera path, framing, lighting, continuity notes and sound cue. The visible action and visual choices are compiled into the actual motion prompt; the old source prompt stays in provenance. The story beat and sound cue remain production notes, rather than being sent to the silent-picture generator. Expand **See the motion prompt** to inspect what will be sent. **Save direction** keeps the plan without rendering. **Test motion · 3.4s Draft** renders a quick 81-frame test. **Render Cinema take** uses the current requested duration and the larger Cinema size. When a reviewed take has a seed, Cinema reuses that seed for comparison without changing your global Keep seed setting. A shared seed does not guarantee identical framing across different sizes.

**Reference** compares the current starting frame with a selected image. Describe a framing or lighting change, then use **Create reference variation**. This calls MLX Core’s installed image models on this Mac, with the actual reference pixels and an instruction edit. It never downloads weights, calls a cloud image service or changes the serving default. The app loads a discovered model when needed, then releases only a model that this request loaded. Models already resident in MLX Core stay resident. Image and video jobs from Stillroom are kept separate, and reference generation waits for a running local ComfyUI render.

Open MLX Core first; its local server must be available on port 11234. **Check models** finds installed image models. This Mac currently has FLUX 4B, FLUX 9B and Qwen Image. Quick creates 768 × 448; Detail creates 1344 × 768. FLUX uses 4 or 12 steps; Qwen uses 20 or 40. These local models differ from the ImageGen model used for the original film references, so this is the same production workflow with different model capabilities. Click either reference image to inspect a larger view.

Every generated reference is a separate library image with its model, prompt, seed and source recorded. **Use this reference** selects it for the current shot’s next generation. Creating a variation alone does not replace the reference or the picture edit. Reference image pixels are normalized to sRGB before use.

**Review & select** reads nine actual frames across a generated take, including its first and last frames. Click a frame to inspect it larger; **Play at 1×** reviews normal motion in the viewer. The sampled-motion note describes pixel change, not artistic quality or identity confidence. New Automatic takes get this note after generation as well. Low motion, large changes, a blink or a camera move can all require different human judgments. The app does not automatically approve faces, hands, props or performance.

Check faces, hands, objects and the action, record notes, and choose **Keep**, **Reject** or **Unreviewed**. Set **In** and **Out** to exclude a weak opening, a bad final frame or a continuity problem. **Save review** records that selection without changing the timeline. **Use selection at 1×** uses only the chosen range at normal speed. **Fit to shot** retimes that range to the existing shot duration and displays its playback speed. Both preserve the original source and can be undone. Changing a shot’s duration moves later picture shots; caption and sound positions remain fixed.

Use the sound cue as a plan for the existing Voice, Room tone, Foley and Score lanes. Shot Studio does not synthesize a voice, clone an actor or generate music. The Edit Assistant can now prepare a small Blender photo insert. You can keep using separate imported sound files and rendered Blender inserts alongside the generated picture.

## Finish the edit with a local AI assistant

Choose **Assistant** in the toolbar or **⇧⌘A**. Ask for a clearer story beat, a stronger ending, a caption revision, a motion prompt, an existing take to try or a small Blender insert. **Check models** finds locally installed chat models in Ollama (port 11434) and MLX Core (port 11234). This Mac already has Qwen 2.5 14B and 1.5B in Ollama. No cloud model, paid API or automatic model download is used.

**Prepare edit plan** sends timeline metadata to the selected local model: shot names, story notes, motion prompts, source IDs, caption wording and timing, sound layer settings and the selected shot. It does not send filesystem paths, images or audio. This is a text-based collaborator: it has not watched the footage, checked faces or heard the mix. It can identify risks in the recorded edit and suggest work, but visual quality and audible balance still need review.

A plan contains a short explanation and individual proposed changes. Check the items you want and choose **Apply selected edits**. This can save a regeneration prompt/camera direction, change an editor zoom, revise caption wording, propose sound gain to audition, or fit an existing source to a shot. Prompt preparation does not start video generation. The assistant cannot delete shots, run commands, write arbitrary Blender code or change caption/sound positions. Timing is protected: replacement footage fits the existing slot, and captions keep their in/out cues. Sound gain suggestions are settings to audition, not measured loudness corrections. One Undo reverses an applied group. If the project changes after a plan is prepared, prepare a fresh plan before applying it.

Blender suggestions have their own **Render Blender insert** button. Use **Connect Blender…** to choose an installed Blender.app. Stillroom builds a real, fixed scene with a textured photograph, a paper border and thickness, a matte tabletop, an area light and an animated 50 mm camera. Choose a slow pullback, slow push in or gentle orbit through the assistant request. This is a photo card in 3D, not a reconstruction of the people or room inside the image. It is useful for a printed-photo insert or a deliberate reveal; use AI motion for actor performances.

The renderer captures the existing image reference (or the source frame when no reference exists), normalizes it to sRGB, packs it into the `.blend`, renders PNG frames with Blender, and encodes a color-tagged MP4 with the installed FFmpeg. The default preview is 960 × 540; **Render at 1080p** uses 1920 × 1080. The render follows the current shot's duration and project frame rate, for slots from 1 to 60 seconds. It adds a separate video candidate and a linked packed Blender project to the library. **Review render** plays it at 1×. **Use render · keep timing** fits it to its target shot while preserving the edit's slot and subtitle/sound positions. The existing source remains available. A render can be cancelled; it is never inserted automatically.

## Create and edit a storyboard (0.9)

Choose **Storyboard** in the toolbar or **⇧⌘B**. The board is saved with the film and travels inside portable `.stillroom` projects. Fold **Film premise & AI draft** to give the cards more space. Keep a premise, visual style and continuity guide for recurring characters and locations.

Choose an installed local chat model and a shot count, then **Draft with local AI**. Review every proposed card before choosing **Use this draft**; drafting alone never replaces the board or edit. You can also use **Board > From current timeline**, add cards manually, or import/export a storyboard JSON. Export shot lists as Markdown for a production handoff. The editor supports up to 32 cards.

Select a card to edit its title, purpose, visible action, one camera move, framing, duration, narration and sound cue. Drag cards to reorder them, or use the arrow buttons. Duplicate and remove cards with the inspector controls. These are planning edits and do not silently change an existing picture edit. Undo restores card changes. Short **On-screen indicator** labels are drawn by the editor in both preview and export, separate from subtitles, so text stays sharp.

Attach an existing **Card frame**, or use an installed local image model to **Create frame**. The first generated frame becomes the continuity reference until you choose another. With no reference, this is text-to-image generation; later frames use the selected image as an identity and setting reference. Quick/Detail determine image size and sampling effort. Every result records the model, seed, prompt and optional input reference, with the original images retained. Check recurring identity, limbs, markings, geometry and props; a reference is guidance rather than a guarantee.

Once every card has a frame or accepted take, **Build timeline** creates frame-aligned picture slots, sparse indicators and provisional subtitle cues from the narration. Put separate subtitle cues on separate lines in a card. Those cues are a planning guide, not speech alignment; import timed SRT after recording narration. Building an unrelated board into an existing picture edit or sound mix is refused. Start a new film for a new story. A linked board can be rebuilt while it has no sound mix. An existing finished film can still be studied and edited as a board without rebuilding it.

After building the timeline, select a card, set a 1–10 second motion length and quality, and choose **Generate motion**. This uses the card’s actual frame, action and camera direction through the existing local video engine. It creates a separate take. **Review latest take** plays it at normal speed; **Use take · fit timing** replaces only that card’s linked shot and keeps its current slot. Fitting short footage into a longer card slows it down. All generated images and takes remain in the library. Add narration and sound lanes, import the final timed subtitles, then export through the main editor.

## Fold and arrange the workspace

Click a disclosure arrow to fold **Timing**, **Camera**, **Source audio**, **Source details**, **Original direction** or **Take notes**. The inspector’s **…** menu expands or collapses all of these sections. Fold choices persist. The regeneration prompt itself also folds.

The native toolbar shows or hides the library, inspector and timeline. Shortcuts are **⌥⌘1**, **⌥⌘2** and **⌥⌘3**. Drag the small handle above the timeline to resize it. The interface follows the system’s light or dark appearance. macOS 26 uses native Liquid Glass controls and navigation; older supported systems use native materials.

## Make a film

1. Choose **File > New Film**, then **Import media**. Videos, photos, sound files and linked `.blend` files can live in the same library. Imported sources remain unchanged.
2. Press the small **+** on a source to add it to the timeline, or drag it into the picture track. Audio creates its own sound layer at the playhead. A linked Blender file opens in Blender, if Blender is installed. Import its rendered movie to use the result in the edit.
3. Select a timeline shot. Set its source in point, source length and speed in the inspector. Still images have a hold duration. Drag the timeline ruler to position the playhead and use **⌘B** to split. Drag a shot onto another shot to move it before that shot. The inspector’s left and right buttons move it one position.
4. Set **Start zoom** and **End zoom** for a slow centered camera move. **Pull back** sets a gradual 1.12× to 1.00× widening. The same camera values reach the exported movie.
5. Keep the generation prompt, a **Keep / Reject / Unreviewed** rating and take notes with each source. The **Story** section holds the film title and creative direction. Review faces, hands and the first and last frames of a generated take before including it.
6. Open **Captions** to import an SRT, edit wording and in/out times, or add a cue at the playhead. Captions appear as small subtitles in the viewer and burn into the export when enabled. You can also export a separate SRT.
7. Select a sound layer to adjust its start, source in point, length, level or mute state. Add voice, continuous room tone, foley and score as separate files. The waveforms show decoded source audio, with each source normalized for display. They are visual guides, not loudness meters.
8. Use **Export film** or **⌘E** for an MP4. Picture, camera moves, enabled subtitles, source sound and sound layers render together.

Click a video in the library to review its source. **Return to edit** restores timeline playback. Click a still to inspect its reference image. Playback stops while you inspect a different source.

## Save the project

**⌘S** saves a portable `.stillroom` package. It contains a readable `project.json` and copies of all linked media, including Blender files. Keep the whole package together. **Save Project As** makes a separate copy.

The current session also recovers automatically after quitting. Before New Film, Load Example or Open Project replaces an unsaved session, Stillroom writes a recovery JSON with absolute source paths. **File > Show Recovery Files** reveals these snapshots. Recovery files depend on the original media remaining available. A portable save includes the media and is the better long-term handoff.

If a source moves, use **Relink** in its inspector. Relinking preserves the source identifier, prompts and shot references. Shorten a trim if the replacement is shorter than the original.

## Integrated local generation

The default **Automatic** engine uses the same free, local LTX-2.3 MLX environment used for this film. Select a shot, describe the change and press **Regenerate**. Stillroom handles engine discovery, the reference-frame upload, the model loader, a continuous image-to-video workflow, queue monitoring, downloading and importing the new take.

The existing environment on this Mac includes approximately 37 GB of video and text-encoder weights. Those weights and the Python environment remain where they were installed; they are not embedded in this app or the download. Do not delete or move that environment without selecting its new location in **Generation settings → Engine options → Choose engine folder**. After first discovery, its location is saved in Application Support, so moving the app to Applications still works.

Stillroom reuses a compatible engine already listening on this Mac. If none is available, it starts a local-only worker on port 8190 using that saved environment, with online model downloads disabled. It never kills or replaces an unrelated server. A worker started by the app can stay running between sessions for reuse. The normal production engine on port 8188 also works. Port 8189 is the film’s status page, not its generation API.

Choose a quality beside the prompt:

| Option | Picture |
|---|---|
| Draft | 768 × 448 |
| Balanced | 1024 × 576 |
| Cinema | 1280 × 704 |

All three use your chosen 1–10 second length, at 24 fps. The nearest supported duration is shown in settings and in the Length control’s help.

The installed distilled model uses its own sampling schedule. Larger takes can take several minutes, depending on memory and what else is running. The generation card shows a gently moving filmstrip, real elapsed time and an estimated remaining-time range. Queue position and render/completion states come from the local engine. Timing estimates use up to three similar successful executions of the same built-in workflow on that engine, scaled to the requested picture size and frame count. Queue wait is excluded. Fully cached renders, failed jobs and different model settings do not contribute. The fill is an estimate, rather than a measured sampling percentage. If the model runs late, the card says so; it never reaches completion before the picture has been retrieved, color-checked and imported. A first run or unsupported custom workflow shows an indeterminate filmstrip and explains that timing is unavailable. Reduce Motion replaces the moving filmstrip with a static track. Use **Draft** to explore a prompt, then **Cinema** for a larger version. “Use take” retimes the generated result to the existing shot duration within the supported 0.1–4× speed range. Very long shots need shorter edits or longer custom workflows.

Automatic motion uses the actual original reference **at frame zero only**, through the standard LTX image-to-video node. Earlier builds repeated the same still at the middle and near the end of the clip, pulling the motion back toward its starting pose. Those repeated anchors are removed. Each generated frame is produced by the video model; the editor does not substitute a pan or zoom of a single still. The recipe records the node used. Identity and camera direction remain model outcomes to review; the application does not promise that every requested movement will be followed.

Write what visibly happens over time: for example, “She lifts her eyes from the laptop, turns toward the window, and leans back as the camera pulls back to reveal the table.” This follows [LTX’s image-to-video prompting guidance](https://ltx.io/blog/ltx-2-3-prompt-guide): the starting image supplies appearance, while the prompt supplies action and camera motion.

**Cancel** stops waiting/importing and removes this job from the queue if it has not started. A running LTX render may finish in the background. Other queued jobs are never cleared. A failed render shows the engine’s error in the prompt area. **Show engine log** reveals the log for the worker started by Stillroom.

macOS may request Documents access when discovering the original production folder. Allow that access or explicitly select the engine folder in settings. Directory discovery runs away from the main interface thread. On another Mac, install a compatible ComfyUI environment with the LTX2 MLX nodes, a Python venv, local LTX video weights and local Gemma weights, then choose its engine folder. This download is an editor with integrated orchestration, not a bundled 37 GB model installation.

### Color consistency

The original reference PNG can carry an HDTV or wide-gamut profile. The model’s image loader reads channel values without applying that profile. Stillroom now converts the actual reference pixels to **sRGB** before upload, rather than changing or discarding the profile label. This avoids passing display-dependent values into the model.

The installed LTX video encoder writes limited-range H.264 using a 601 conversion matrix without declaring its color information. For this known Automatic workflow, Stillroom fills the correct **709 primaries, sRGB transfer and 601 matrix** using a lossless stream copy. The picture is not recompressed or desaturated. Existing complete color tags from other workflows are preserved. This step uses FFmpeg from the installed local production environment, normally `/opt/homebrew/bin/ffmpeg`.

Native picture plates and MLX video encoding now carry explicit color information too. The subtitle compositor honors each source frame’s color description and performs one consistent conversion into the output space. Checks with a four-patch chart, using both sRGB and Rec.709 video sources, found maximum sampled RGB errors below 0.009 on a 0–1 scale through plain and subtitle exports. P3-to-sRGB reference conversion and lossless LTX metadata repair were also checked. These are software transport checks; the generative model can still change lighting or color. Regenerate older takes with this version to use the corrected color path.

The handling follows [Apple’s video color guidance](https://developer.apple.com/documentation/avfoundation/tagging-media-with-video-color-information), [custom compositor color conformance](https://developer.apple.com/documentation/avfoundation/avvideocompositing/canconformcolorofsourceframes) and [FFmpeg’s H.264 metadata filter](https://ffmpeg.org/ffmpeg-bitstream-filters.html#h264_005fmetadata).

### Optional custom engines

Advanced users can expand **Engine options** and choose **MLX-Serve** or **ComfyUI workflow**. All connections are restricted to HTTP loopback on this Mac. No cloud account, paid video API or credit purchase is used.

For MLX-Serve, load a compatible video model and connect to its local server, usually port 11234. Image-only models are not video models. This adapter accepts `/v1/video/generations` with an `rgb8` response and encodes the picture locally; generated sound is not imported.

For a custom ComfyUI graph, choose Export (API) JSON and identify the positive prompt node. The selected reference replaces all LoadImage inputs, and the seed replaces all seed inputs. Other settings come from that custom workflow. A video-save node must report an MP4 or MOV in history. The built-in Automatic workflow needs none of these manual settings.

## Verification for this build

The complete 0.7 workflow was exercised in the native app. FLUX 9B generated a **1344 × 768 reference variation in 12 steps**, using the actual original reference pixels. The image was explicitly chosen for the next take. Its owned model was released afterward. A planned **81-frame, 1024 × 576, 3.38-second** local LTX take then used exactly those uploaded reference pixels and the saved camera/continuity direction. Nine frames were sampled automatically and opened in Review & select.

The new take has a clear gaze turn and a more coherent laptop than the previous test. The camera still widens despite the locked-camera instruction; the saved review notes flag that limitation and leave hand movement for further review. The take remains **Unreviewed**, rather than being automatically marked Keep. Its suggested **0.25–2.90 s** range was saved, applied at **1× for 2.65 seconds**, then undone. The original picture edit, caption cues and sound settings were compared with the session before testing and restored exactly.

The new image, plan, take and review are available in this Mac’s recovered session, as **Reference variation · Explaining a guess** and **Take 10**. The reference remains selected for the shot’s next generation. **3.4 seconds / Balanced** remains ready. `Shot-Studio-Reference.png` and `Regeneration-Example.mp4` are the actual image and full native take from this check; they can be imported on another Mac. The selected range stays in the take’s review metadata on this Mac. The bundled example film itself stays as the original editable scene study.

Earlier motion verification (0.6): The 0.6 motion correction was checked with a new **81-frame, 1024 × 576, 24 fps, 3.38-second** take, using the same original reference and requested motion as the previous near-static take. It completed in about **3 minutes 49 seconds**. Native samples show a head turn and a camera pullback that reveals more of the table and room, without being forced back to the original pose. The laptop/foreground geometry shifts during the move, so this is a motion verification sample, not a production-approved shot. Review continuity before accepting it.

**Play take · 1×** was checked in the native app: playback advanced to the end without pressing a second Play control. The previous picture edit, captions and sound layers remained unchanged. The new render is **Take 9** in this Mac’s recovered session. Your **3.4-second request and Balanced quality** were kept. That version’s example contained its new color-tagged take; the current example is the 0.7 take described above. Existing takes remain available but need regenerating to use the corrected motion path.

Earlier progress verification (0.5): The animated progress card was checked during a real two-second Draft render: **49 frames, 768 × 448, 2.04 seconds**, completed in about **94 seconds**. Queue, remaining-time updates, folded progress, creation settings and the completed bar were checked in the native app. The original picture edit, captions and sound layers were unchanged. The test is available as Take 6 in this Mac’s recovered session; your preceding ten-second render remains Take 5. The ten-second request and Balanced quality were restored afterward.

Earlier length and color verification: the release app generated a real five-second request as **121 frames, 768 × 448, 24 fps, 5.04 seconds**, in about 3 minutes 15 seconds. The model received an sRGB reference. The resulting H.264 file declares its range, primaries, transfer function and matrix. All 121 decoded frame hashes were identical before and after the lossless color metadata repair.

The native interface was checked through **Length 5 → Regenerate → Preview → clock menu → Use generated length → Undo**. The new shot played at 1× for 5.04 seconds. Undo restored the original 13.92-second shot and 2:31 film. Picture, caption and sound settings were compared with the saved session before the test. The fourth take remains in this Mac’s recovered session for comparison. That earlier check used Balanced quality and a five-second request afterward. The downloadable example now comes from the 0.7 workflow check described above.

The normal test run has **38 tests, with no failures**; two slow local-engine checks are opt-in. New checks cover compiled shot direction, selected-range timing, nine-frame sampling, saved review/provenance, actual-reference image uploads, explicit reference selection, resident-model preservation, failure cleanup and avoiding concurrent local video/image jobs. The playback check verifies that a take advances at 1×, preserves the edit and can restart after reaching its end. Workflow checks require a frame-zero reference without forced middle/end images or strengths. Checks also cover queue wait exclusion, compatible render timing, cached/error sample rejection, late estimates and completion boundaries. Checks cover legal frame counts, actual-length replacement, source-frame extraction, automatic workflow preparation, upload/download, useful errors, original preservation, saved recipes, old project compatibility, P3 reference conversion, color metadata repair, and native exports. sRGB and Rec.709 color charts passed both plain and subtitle exports, with maximum sampled RGB errors below 0.009. The engine startup and real-model paths have also been checked separately.

## Included example

The example contains **12 shots, 25 sources, 27 editable captions and four sound stems**, running 2:31. It uses the original fictional ImageGen references, seven native local AI takes, two clean Blender inserts and separately encoded audio stems. The opening uses its image reference with a camera push.

This scene study is editable source material, rather than a frame-identical copy of the finished film. The original film’s optical-flow processing, bespoke graphic labels, foreground rain and individual color grades are not baked into these native takes. Camera transforms use a centered crop. Three early image prompts are reconstructed specifications as disclosed in the source notes. All depicted people and family photographs are fictional. Voices are synthetic Kokoro performances. No human voice was cloned.

Recording attribution is in the bundled `Sound-credits.md`. The sound stems include the original project’s CC0 rain, door and paper recordings and original sparse score. The source film’s mastering measurements do not describe a newly edited export from this app.

## Current scope

This version provides one sequential picture track, independent sound layers and timed subtitles. Picture edits do not automatically move the absolute caption and sound times. Retime those layers after changing the structure. Speed changes use native frame sampling and affect enabled source audio. There is no optical-flow interpolation, transition editor, color-grading suite, automatic lip sync, loudness mastering or in-app Blender rendering yet.

Design references: [Apple’s native Liquid Glass guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and the sidebar, content and detail organization in [MLX-Serve’s Mac app](https://github.com/ddalcu/mlx-serve/blob/main/docs/app.md). Stillroom’s interface and code were made directly for this project. It is an independent app, not an MLX-Serve product.

## Keyboard controls

| Action | Shortcut |
|---|---|
| Play or pause | Space |
| Step a frame | Left / Right |
| Step a second | Shift + Left / Right |
| Import | ⌘I |
| Split | ⌘B |
| Remove selection | Delete |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Save portable project | ⌘S |
| Export film | ⌘E |
| Local creation | ⌘G |

Text fields retain normal typing behavior. The editable Swift source is in `Source/`.

### Separate the opening image from the movement

Use **Opening pose · still image** to describe one frozen instant: who is visible, where they stand, and the composition. Keep the sequence of movements in **Visible action**. Frame generation uses the opening pose when supplied; motion generation continues to use the action. This reduces the chance of showing the same moving subject several times in one reference image. Older boards remain compatible.
