# Icon pipeline philosophy — yquake2 PPC port

Read this if you touch `scripts/make-icon.py` or regenerate `Quake2.icns`.

`scripts/make-icon.py` ships **conservative defaults**: edge-flood-fill
bg removal that preserves all interior detail, no auto-scrubbing of
interior bg-coloured pockets. The `--scrub-interior` knob exists for AI-
generated artwork that has bg leaking through logo glyph gaps or
detail-sparse areas, but the heuristics (size + score-purity + annulus
darkness) can't reliably distinguish bg-bleed from saturated specular
highlights on metallic surfaces.

**Use Photoshop touch-up over algorithmic perfection.** The proven
workflow for the Q1+Q2 icons we shipped:
1. Run `make-icon.py` with defaults to produce a conservative
   transparent-bg master + a magenta-composited preview.
2. User opens the master in Photoshop, paints any visible bg pockets
   to alpha=0 using the magenta preview as a guide.
3. User saves back as RGBA PNG, hands it back via `--keep-bg` to
   regenerate the ICNS without re-running bg removal.

Don't burn cycles trying to make `--scrub-interior` work perfectly on a
new artwork — if defaults leave visible bg pockets, ship to Photoshop.
