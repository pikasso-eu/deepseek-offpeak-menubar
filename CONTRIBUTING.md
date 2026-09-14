# Contributing

Thanks for your interest! This is a small, single-file Swift project, so
contributions are easy to review.

## Build & test

```bash
./build.sh
build/DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --selftest   # must pass
build/DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --text
```

`--selftest` covers the pricing windows (including the weekend rule that changed
on 2026-08-23), configuration sanitising, balance JSON decoding and log file
name detection. Please keep it green and extend it when you change logic.

## Adding a translation

1. Copy `Resources/en.lproj/Localizable.strings` to `Resources/<code>.lproj/`.
2. Translate the **values** only. Keep `%@`, `%d`, `%%` and `\n` placeholders
   exactly as they are – the keys are English format strings.
3. Add the language code to `CFBundleLocalizations` in `Info.plist`.
4. Test with `"language": "<code>"` in the configuration file.

## Reporting issues

Useful details for pricing/usage bugs:

- macOS version and app version (`--version`)
- the output of `--selftest`
- for usage/cost issues: the *structure* of a session log line (never paste
  your prompts or keys), e.g. `zstd -d -c ~/.dsh/sessions/…/session.v3.jsonl.zstd | head -1`
- for balance issues: the HTTP status, not the API key

## Scope

The project focuses on **macOS menu bar notifications about DeepSeek pricing,
balance and local session costs**. Keep changes small and dependency-free.

## Notes

- Code comments are partly German from the original author; feel free to
  translate them while touching a file.
- No secrets, no personal paths and no `.env` files in commits, please.
