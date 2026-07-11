FROM rust:1.94-bookworm AS build
WORKDIR /src
COPY plugin-runner/Cargo.toml plugin-runner/Cargo.toml
COPY plugin-runner/Cargo.lock plugin-runner/Cargo.lock
COPY plugin-runner/src plugin-runner/src
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/plugin-runner/target \
    cargo build --manifest-path plugin-runner/Cargo.toml --release --locked && \
    cp plugin-runner/target/release/luminavault-plugin-runner /tmp/luminavault-plugin-runner

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /tmp/luminavault-plugin-runner /usr/local/bin/plugin-runner
USER nonroot:nonroot
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/plugin-runner"]
