use std::{collections::HashSet, sync::Arc, time::Duration};

use anyhow::{Context, Result, anyhow, bail};
use axum::{
    Json, Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;
use tokio::time::timeout;
use wasmtime::{Caller, Config, Engine, Linker, Module, Store, StoreLimits, StoreLimitsBuilder, TypedFunc};

const MAX_MODULE_BYTES: usize = 10 * 1024 * 1024;
const MAX_INPUT_BYTES: usize = 1024 * 1024;
const MAX_OUTPUT_BYTES: usize = 1024 * 1024;
const MAX_MEMORY_BYTES: usize = 64 * 1024 * 1024;
const DEFAULT_FUEL: u64 = 10_000_000;

#[derive(Clone)]
struct AppState {
    engine: Engine,
    token: Arc<str>,
}

struct StoreState {
    limits: StoreLimits,
    permissions: HashSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExecuteRequest {
    module_base64: String,
    tool_name: String,
    permissions: Vec<String>,
    input: serde_json::Value,
    fuel: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExecuteResponse {
    output: serde_json::Value,
    fuel_consumed: u64,
}

#[derive(Serialize)]
struct ErrorBody {
    error: &'static str,
}

#[tokio::main]
async fn main() -> Result<()> {
    if std::env::args().any(|argument| argument == "--healthcheck") {
        return Ok(());
    }
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let token = std::env::var("PLUGIN_RUNNER_TOKEN").context("PLUGIN_RUNNER_TOKEN is required")?;
    if token.len() < 32 {
        bail!("PLUGIN_RUNNER_TOKEN must contain at least 32 characters");
    }
    let mut config = Config::new();
    config.consume_fuel(true);
    config.epoch_interruption(true);
    config.cranelift_nan_canonicalization(true);
    let engine = wasmtime_result(Engine::new(&config))?;
    let epoch_engine = engine.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(100));
        loop {
            interval.tick().await;
            epoch_engine.increment_epoch();
        }
    });

    let state = AppState { engine, token: token.into() };
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/execute", post(execute))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8090").await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(async { let _ = tokio::signal::ctrl_c().await; })
        .await?;
    Ok(())
}

async fn execute(State(state): State<AppState>, headers: HeaderMap, Json(request): Json<ExecuteRequest>) -> Response {
    if !authorized(&headers, &state.token) {
        return (StatusCode::UNAUTHORIZED, Json(ErrorBody { error: "unauthorized" })).into_response();
    }
    let future = tokio::task::spawn_blocking(move || execute_sync(state, request));
    match timeout(Duration::from_secs(30), future).await {
        Ok(Ok(Ok(response))) => (StatusCode::OK, Json(response)).into_response(),
        Ok(Ok(Err(error))) => {
            tracing::warn!(error = %error, "plugin execution rejected");
            (StatusCode::UNPROCESSABLE_ENTITY, Json(ErrorBody { error: "execution_failed" })).into_response()
        }
        Ok(Err(error)) => {
            tracing::error!(error = %error, "plugin worker join failed");
            (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorBody { error: "runner_failed" })).into_response()
        }
        Err(_) => (StatusCode::REQUEST_TIMEOUT, Json(ErrorBody { error: "execution_timeout" })).into_response(),
    }
}

fn execute_sync(state: AppState, request: ExecuteRequest) -> Result<ExecuteResponse> {
    let module_bytes = STANDARD.decode(request.module_base64).context("invalid module base64")?;
    if module_bytes.len() > MAX_MODULE_BYTES { bail!("module_too_large"); }
    let mut input_value = request.input;
    if let Some(object) = input_value.as_object_mut() {
        object.insert("_tool".into(), serde_json::Value::String(request.tool_name));
    }
    let input = serde_json::to_vec(&input_value)?;
    if input.len() > MAX_INPUT_BYTES { bail!("input_too_large"); }

    wasmtime_result(Module::validate(&state.engine, &module_bytes))?;
    let module = wasmtime_result(Module::new(&state.engine, module_bytes))?;
    let allowed_imports = HashSet::from([
        "memory_read_allowed", "memory_write_allowed", "vault_read_allowed",
        "vault_write_allowed", "network_fetch_allowed", "output_emit_allowed",
    ]);
    if module.imports().any(|import| import.module() != "luminavault" || !allowed_imports.contains(import.name())) {
        bail!("module_imports_forbidden");
    }
    let limits = StoreLimitsBuilder::new()
        .memory_size(MAX_MEMORY_BYTES)
        .memories(1)
        .instances(1)
        .tables(1)
        .trap_on_grow_failure(true)
        .build();
    let permissions = request.permissions.into_iter().collect();
    let mut store = Store::new(&state.engine, StoreState { limits, permissions });
    store.limiter(|state| &mut state.limits);
    let fuel = request.fuel.unwrap_or(DEFAULT_FUEL).min(DEFAULT_FUEL);
    wasmtime_result(store.set_fuel(fuel))?;
    store.set_epoch_deadline(300);
    let mut linker = Linker::new(&state.engine);
    define_capability(&mut linker, "memory_read_allowed", "memory.read")?;
    define_capability(&mut linker, "memory_write_allowed", "memory.write")?;
    define_capability(&mut linker, "vault_read_allowed", "vault.read")?;
    define_capability(&mut linker, "vault_write_allowed", "vault.write")?;
    define_capability(&mut linker, "network_fetch_allowed", "network.fetch")?;
    define_capability(&mut linker, "output_emit_allowed", "output.emit")?;
    let instance = wasmtime_result(linker.instantiate(&mut store, &module))?;
    let memory = instance.get_memory(&mut store, "memory").context("memory export required")?;
    let alloc: TypedFunc<i32, i32> = wasmtime_result(instance.get_typed_func(&mut store, "alloc"))
        .context("alloc export required")?;
    let run: TypedFunc<(i32, i32), i64> = wasmtime_result(instance.get_typed_func(&mut store, "run"))
        .context("run export required")?;
    let input_ptr = wasmtime_result(alloc.call(&mut store, i32::try_from(input.len())?))?;
    memory.write(&mut store, usize::try_from(input_ptr)?, &input)?;
    let packed = wasmtime_result(run.call(&mut store, (input_ptr, i32::try_from(input.len())?)))? as u64;
    let output_ptr = (packed >> 32) as usize;
    let output_len = (packed & 0xffff_ffff) as usize;
    if output_len > MAX_OUTPUT_BYTES { bail!("output_too_large"); }
    let mut output = vec![0_u8; output_len];
    memory.read(&store, output_ptr, &mut output)?;
    let output: serde_json::Value = serde_json::from_slice(&output).context("output must be json")?;
    let remaining = wasmtime_result(store.get_fuel())?;
    Ok(ExecuteResponse { output, fuel_consumed: fuel.saturating_sub(remaining) })
}

fn wasmtime_result<T>(result: std::result::Result<T, wasmtime::Error>) -> Result<T> {
    result.map_err(|error| anyhow!(error.to_string()))
}

fn define_capability(linker: &mut Linker<StoreState>, name: &'static str, permission: &'static str) -> Result<()> {
    wasmtime_result(linker.func_wrap("luminavault", name, move |caller: Caller<'_, StoreState>| -> i32 {
        i32::from(caller.data().permissions.contains(permission))
    }))?;
    Ok(())
}

fn authorized(headers: &HeaderMap, expected: &str) -> bool {
    let Some(value) = headers.get("authorization").and_then(|value| value.to_str().ok()) else { return false; };
    let Some(presented) = value.strip_prefix("Bearer ") else { return false; };
    presented.as_bytes().ct_eq(expected.as_bytes()).into()
}
