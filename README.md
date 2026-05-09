# ObsidianClaudeBrainServer

Backend API for ObsidianClaudeBrain — a lightweight, OpenAPI-first Hummingbird 2 server written in Swift 6.

## Responsibilities

- User authentication & subscription management
- Optional encrypted vault sync (multi-device)
- LLM call proxying / orchestration (optional, user keys)
- Analytics and memory graph computation (future)

## Tech stack

- **Swift 6** with structured concurrency
- **Hummingbird 2** — lightweight, modular HTTP server
- **swift-openapi-generator** — API contract defined in `openapi.yaml`, types and handlers generated at build time
- **swift-configuration** — layered config (CLI args → env vars → `.env` file → defaults)

## Project structure

```
Sources/
├── App/
│   ├── App.swift                          # Entry point (@main)
│   ├── App+build.swift                    # Application + router setup
│   ├── APIImplementation.swift            # OpenAPI handler implementations
│   └── OpenAPIRequestContextMiddleware.swift
└── AppAPI/
    ├── openapi.yaml                       # API contract (source of truth)
    ├── openapi-generator-config.yaml      # Generator config
    └── AppAPI.swift                       # Generated types (do not edit)
```

## Prerequisites

- Swift 6.2+
- macOS 15+ (for local dev)
- Docker (for deployment)

## Running locally

```bash
swift run App
```

Configuration is read in this order: CLI args → environment variables → `.env` file → in-memory defaults.

```bash
# Example .env
LOG_LEVEL=debug
HTTP_PORT=8080
```

## Running with Docker

```bash
docker build -t obsidian-claude-brain-server .
docker run -p 8080:8080 obsidian-claude-brain-server
```

## API contract

The API is defined in [`Sources/AppAPI/openapi.yaml`](Sources/AppAPI/openapi.yaml).  
Swift types and route stubs are generated automatically by `swift-openapi-generator` at build time — edit `openapi.yaml` to extend the API, then implement the new operations in `APIImplementation.swift`.

## Adding a new endpoint

1. Add the path + operation to `openapi.yaml`
2. Build (`swift build`) — the generator creates the Swift protocol method
3. Implement the method in `APIImplementation.swift`
4. Add a test in `Tests/AppTests/`
# HermiesVaultServer
# LuminaVaultServer
# LuminaVaultServer
