# AGENTS.md

## Project Overview

This is a darktable Lua plugin that uses a local AI Vision-Language Model (VLM) via an OpenAI-compatible endpoint to generate AI-powered caption suggestions for photos. The captions follow AP Photo editorial style guidelines.

## Structure

```
ai_caption/
├── lua/
│   ├── ai_caption.lua      # Main plugin: panel UI, actions (suggest/apply/clear)
│   └── lib/
│       └── ai_vlm.lua      # VLM API helper: image handling, prompt building, API calls
```

## Key Files

- **`lua/ai_caption.lua`** - Darktable plugin entry point. Registers panel in lighttable view, handles user interactions (Suggest, Apply, Clear buttons), manages panel state.
- **`lua/lib/ai_vlm.lua`** - Core VLM interaction library. Handles image encoding/resizing, reverse geocoding via OSM Nominatim, prompt construction with metadata context, API request/response handling.

## Caption Format

Captions follow AP Photo editorial guidelines:
- **Sentence 1** (present tense): Who and what, where and when
- **Sentence 2** (past tense): Why or how the event occurred
- Ends with photo credit: `(Publisher/Creator)` or `(Publisher)` or `(Creator)`

## Dependencies

- darktable Lua API (minimum 7.0.0)
- OpenAI-compatible VLM endpoint
- ImageMagick (`convert` command for image resizing)
- `curl` for API requests
- OSM Nominatim for reverse geocoding (optional, uses image GPS data)

## VLM Prompt Context

The prompt automatically includes:
- Film roll name context (extracted meaningful parts)
- Capture date (formatted as "Month Day, Year")
- Location (reverse geocoded via Nominatim from GPS coordinates)
- User-provided additional context
- Photo credit (from publisher/creator metadata)

## Preferences

Configurable via darktable preferences:
- VLM endpoint URL
- Model name
- Max tokens (50-8192, default 4096)
- Temperature (0.0-1.0, default 0.6)
- Max image dimension (256-4096, default 1024)
- Panel position

## Development Notes

- RAW files are automatically exported to JPEG before sending to VLM
- Image groups are handled: uses first non-RAW member if available
- All temp files are cleaned up after use
- Uses custom JSON parser (no external dependencies)

## Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

- **type**: feat, fix, docs, style, refactor, test, chore
- **scope**: optional, indicates which part of the code (e.g., vlm, prompt, panel)
- **description**: brief summary in imperative mood
- **body**: one or more paragraphs explaining the what and why
- **footer**: breaking changes, issue references, other metadata

Example:

```
feat(vlm): add AP Photo-style caption generation

Update VLM prompt to follow AP Photo editorial guidelines with
two-sentence structure: present tense for who/what/where/when,
and past tense for why/how context.

Photo credits are now pulled from image metadata and appended
at the end of the description.

Closes #12
```
