# Porthole UI artwork

`porthole-icon-paths.json` contains the approved icon paths from the PC repository's `branding/porthole/source/paths.json`. The Connect tab uses that original geometry, including the cursor gap and both reflection stripes.

The sharing control uses the reviewed UI variant: a 19-unit rim in a 380-unit canvas, the original cursor outline scaled to 60%, and smaller reflection stripes. This variant does not replace the app icon or the brand master.

The light and dark PDFs in `PortholePull/Assets.xcassets` retain vector paths and transparent cursor clearance. The navbar PDF has a 32-point canvas with 24-point artwork. Their original rendering preserves the grey reflections.

To rebuild the PDFs, install Pycairo and run `python3 scripts/export-brand-assets.py`. The app build does not need Python or Cairo. Add `--preview-dir <directory>` to export matching SVGs for visual review.
