# Rejected G4 model range hints

The earlier Radeon 9200 profile showed time in indexed model submission inside
the driver. The candidate supplied known bounds through glDrawRangeElements,
gated by gl_mesh_drawrange and GL 1.2 or EXT support. The rationale follows the
[extension specification](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_draw_range_elements.txt).
It did not produce a useful measured improvement on this machine.

At 1024x768, demo1 A/B/B/A, three runs each, warm results were
55.65 / 55.70 / 55.70 / 55.70 fps. Both modes retained combined clears,
MSAA2, projected shadows, indexed models and the same lighting. The ten frame
pairs had zero different pixels according to ImageMagick AE; PNG metadata
differs. A selected pair is retained here and was visually inspected.

The CSV commit is the checkout label, not the experimental renderer identity.
This was a temporary thin G4 renderer beside the old installed engine. Hashes,
source stamp, config files and the rejected source patch identify the test.
The patch also includes the unit tests; later capability-gate test additions
did not change the renderer that was built. ASan/UBSan tests passed.

Reverted the engine and test changes. Original renderer and normal config were
restored, with matching original/restored MD5. The G4 remained muted. This is
not a finding about other GPU drivers, and not evidence of a new FPS gain.

An initial attempt exceeded the engine's 50-argument limit and never produced a
benchmark log. It was excluded. The measured runs load the settings via +exec.
