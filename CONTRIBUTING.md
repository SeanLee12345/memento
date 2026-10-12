# Contributing to Memento

Open an issue with the user flow, expected behavior, and reproduction steps before proposing a substantial change. For device issues, include the iPhone model, iOS version, glasses model, firmware, and DAT version.

## Development

1. Follow the setup in [README.md](README.md) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
2. Keep changes scoped to the app, backend functions, or relevant worker.
3. Follow the DAT lifecycle and audio-output guidance in [AGENTS.md](AGENTS.md).
4. Run the tests closest to your change and describe the results in your pull request. State whether verification used a simulator, mocks, or physical glasses.

Keep local credentials, recordings, person profiles, and conversation exports outside version control. Use synthetic fixtures for tests and remove personal content from issue attachments.
