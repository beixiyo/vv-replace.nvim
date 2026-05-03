# Changelog

## [Unreleased]

### Added
- **Live preview**: moving cursor over result items automatically opens the corresponding file and line in the source window (without switching focus).
- **File-level diff preview**: when entering a file's results, all matches in that file are highlighted in the source window — matched text shown as removed (red), replacement as inline virtual text (green).
- Added `<Esc>` mapping to close the panel in normal mode.

### Changed
- **Single-line inline diff**: replace preview in the results panel now uses one line per match (matched text highlighted + replacement as inline virtual text), instead of two separate lines. Faster `j`/`k` navigation.
