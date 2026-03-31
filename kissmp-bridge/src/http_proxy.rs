use percent_encoding::percent_decode_str;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone, Serialize)]
struct MasterBatchJobState {
    state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    server_list: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    errors: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    masters_total: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    masters_ok: Option<usize>,
}

#[derive(Deserialize)]
struct MasterBatchStartRequest {
    masters: Vec<String>,
    version: String,
}

#[derive(Deserialize)]
struct ServerHostData {
    name: String,
    max_players: u8,
    map: String,
    mods: Option<Vec<String>>,
    port: u16,
}

fn merge_server_objects(target: &mut Map<String, Value>, incoming: &Map<String, Value>) {
    for (addr, server) in incoming {
        target.entry(addr.clone()).or_insert_with(|| server.clone());
    }
}

async fn fetch_master_list_json(
    client: &reqwest::Client,
    master_base_url: &str,
    version: &str,
) -> Result<Map<String, Value>, String> {
    let base = master_base_url.trim().trim_end_matches('/');
    if base.is_empty() {
        return Err("master url is empty".to_string());
    }

    let version_path = version.trim().trim_matches('/');
    let version_path = if version_path.is_empty() {
        "latest"
    } else {
        version_path
    };

    let url = format!("{}/{}", base, version_path);
    log::debug!("[master_batch] fetching {}", url);
    let response = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("{} ({})", url, e))?;

    let body = response
        .text()
        .await
        .map_err(|e| format!("{} (failed reading body: {})", url, e))?;

    if body.starts_with("proxy_error:") {
        return Err(format!("{} ({})", url, body));
    }

    if body.contains("outdated version of KissMP") {
        return Err(format!("{} (version mismatch)", url));
    }

    let decoded: Value =
        serde_json::from_str(&body).map_err(|e| format!("{} (invalid json: {})", url, e))?;
    if let Some(obj) = decoded.as_object() {
        log::debug!("[master_batch] fetched {} entries from {}", obj.len(), url);
        Ok(obj.clone())
    } else {
        Err(format!("{} (json root is not an object)", url))
    }
}

pub async fn spawn_http_proxy(discord_tx: std::sync::mpsc::Sender<crate::DiscordState>) {
    // Master server proxy
    //println!("start");
    let server = tiny_http::Server::http("0.0.0.0:3693").unwrap();
    let mut destroyer: Option<tokio::sync::oneshot::Sender<()>> = None;
    let master_batch_jobs: Arc<Mutex<HashMap<String, MasterBatchJobState>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let next_batch_id = Arc::new(AtomicU64::new(1));
    loop {
        for request in server.incoming_requests() {
            let addr = request.remote_addr();
            if addr.ip() != Ipv4Addr::new(127, 0, 0, 1) {
                continue;
            }
            let mut url = request.url().to_string();
            //println!("{:?}", url);
            url.remove(0);
            if url == "check" {
                let response = tiny_http::Response::from_string("ok");
                request.respond(response).unwrap();
                continue;
            }
            if url.starts_with("master_batch/start/") {
                let data = url.replace("master_batch/start/", "");
                let data = percent_decode_str(&data).decode_utf8_lossy().into_owned();
                let payload = match serde_json::from_str::<MasterBatchStartRequest>(&data) {
                    Ok(payload) => payload,
                    Err(err) => {
                        let response = tiny_http::Response::from_string(
                            json!({ "error": format!("invalid batch request payload: {}", err) })
                                .to_string(),
                        );
                        request.respond(response).unwrap();
                        continue;
                    }
                };

                if payload.masters.is_empty() {
                    let response = tiny_http::Response::from_string(
                        json!({ "error": "masters list is empty" }).to_string(),
                    );
                    request.respond(response).unwrap();
                    continue;
                }

                let batch_id = next_batch_id.fetch_add(1, Ordering::Relaxed).to_string();
                log::info!(
                    "[master_batch] start request_id={} masters={} version={}",
                    batch_id,
                    payload.masters.len(),
                    payload.version
                );
                {
                    let mut jobs = master_batch_jobs.lock().unwrap();
                    jobs.insert(
                        batch_id.clone(),
                        MasterBatchJobState {
                            state: "pending".to_string(),
                            server_list: None,
                            errors: None,
                            masters_total: None,
                            masters_ok: None,
                        },
                    );
                }

                let jobs = master_batch_jobs.clone();
                let batch_id_for_task = batch_id.clone();
                std::thread::spawn(move || {
                    let runtime = match tokio::runtime::Runtime::new() {
                        Ok(runtime) => runtime,
                        Err(err) => {
                            log::error!(
                                "[master_batch] request_id={} failed to create tokio runtime: {}",
                                batch_id_for_task,
                                err
                            );
                            let mut jobs = jobs.lock().unwrap();
                            jobs.insert(
                                batch_id_for_task,
                                MasterBatchJobState {
                                    state: "done".to_string(),
                                    server_list: Some(Value::Object(Map::new())),
                                    errors: Some(vec![format!("failed to create tokio runtime: {}", err)]),
                                    masters_total: Some(0),
                                    masters_ok: Some(0),
                                },
                            );
                            return;
                        }
                    };

                    runtime.block_on(async move {
                        let client = match reqwest::Client::builder()
                            .timeout(Duration::from_secs(4))
                            .build()
                        {
                            Ok(client) => client,
                            Err(err) => {
                                log::error!(
                                    "[master_batch] request_id={} failed to create reqwest client: {}",
                                    batch_id_for_task,
                                    err
                                );
                                let mut jobs = jobs.lock().unwrap();
                                jobs.insert(
                                    batch_id_for_task.clone(),
                                    MasterBatchJobState {
                                        state: "done".to_string(),
                                        server_list: Some(Value::Object(Map::new())),
                                        errors: Some(vec![format!("failed to build http client: {}", err)]),
                                        masters_total: Some(0),
                                        masters_ok: Some(0),
                                    },
                                );
                                return;
                            }
                        };

                        let mut pending = futures::stream::FuturesUnordered::new();
                        let mut unique_masters = std::collections::HashSet::new();
                        for master in payload.masters {
                            let trimmed = master.trim().trim_end_matches('/').to_string();
                            if trimmed.is_empty() || !unique_masters.insert(trimmed.clone()) {
                                continue;
                            }
                            let version = payload.version.clone();
                            let client = client.clone();
                            pending.push(async move {
                                let result = fetch_master_list_json(&client, &trimmed, &version).await;
                                (trimmed, result)
                            });
                        }

                        let mut merged = Map::new();
                        let mut errors = Vec::new();
                        let mut masters_ok = 0usize;
                        let mut masters_total = 0usize;
                        while let Some((master, result)) = futures::StreamExt::next(&mut pending).await {
                            masters_total += 1;
                            match result {
                                Ok(server_list) => {
                                    masters_ok += 1;
                                    log::info!(
                                        "[master_batch] request_id={} master={} ok servers={}",
                                        batch_id_for_task,
                                        master,
                                        server_list.len()
                                    );
                                    merge_server_objects(&mut merged, &server_list);
                                }
                                Err(err) => {
                                    log::warn!(
                                        "[master_batch] request_id={} master={} failed: {}",
                                        batch_id_for_task,
                                        master,
                                        err
                                    );
                                    errors.push(format!("{}: {}", master, err));
                                }
                            }
                        }

                        log::info!(
                            "[master_batch] request_id={} done masters_ok={}/{} merged_servers={}",
                            batch_id_for_task,
                            masters_ok,
                            masters_total,
                            merged.len()
                        );

                        let mut jobs = jobs.lock().unwrap();
                        jobs.insert(
                            batch_id_for_task,
                            MasterBatchJobState {
                                state: "done".to_string(),
                                server_list: Some(Value::Object(merged)),
                                errors: if errors.is_empty() { None } else { Some(errors) },
                                masters_total: Some(masters_total),
                                masters_ok: Some(masters_ok),
                            },
                        );
                    });
                });

                let response = tiny_http::Response::from_string(
                    json!({ "request_id": batch_id }).to_string(),
                );
                request.respond(response).unwrap();
                continue;
            }
            if url.starts_with("master_batch/status/") {
                let batch_id = url.replace("master_batch/status/", "");
                let state = {
                    let jobs = master_batch_jobs.lock().unwrap();
                    jobs.get(&batch_id).cloned()
                };

                if let Some(state) = &state {
                    log::debug!(
                        "[master_batch] status request_id={} state={}",
                        batch_id,
                        state.state
                    );
                } else {
                    log::debug!("[master_batch] status request_id={} state=missing", batch_id);
                }

                let response_body = if let Some(state) = state {
                    serde_json::to_string(&state).unwrap_or_else(|_| {
                        json!({ "state": "done", "server_list": {}, "errors": ["failed to serialize job state"] })
                            .to_string()
                    })
                } else {
                    json!({ "state": "missing" }).to_string()
                };

                let response = tiny_http::Response::from_string(response_body);
                request.respond(response).unwrap();
                continue;
            }
            if url.starts_with("rich_presence") {
                let server_name_encoded = url.replace("rich_presence/", "");
                let data = percent_decode_str(&server_name_encoded)
                    .decode_utf8_lossy()
                    .into_owned();
                let server_name = {
                    if data != "none" {
                        Some(data)
                    } else {
                        None
                    }
                };
                let state = crate::DiscordState { server_name };
                let _ = discord_tx.send(state);
                let response = tiny_http::Response::from_string("ok");
                request.respond(response).unwrap();
                continue;
            }
            if url.starts_with("host") {
                let data = url.replace("host/", "");
                let data = percent_decode_str(&data).decode_utf8_lossy().into_owned();
                if let Some(destroyer) = destroyer {
                    let _ = destroyer.send(());
                }
                let (destroyer_tx, destroyer_rx) = tokio::sync::oneshot::channel();
                let (setup_result_tx, mut setup_result_rx) = tokio::sync::oneshot::channel();
                destroyer = Some(destroyer_tx);
                std::thread::spawn(move || {
                    let data: ServerHostData = serde_json::from_str(&data).unwrap();
                    let config = kissmp_server::config::Config {
                        server_name: data.name,
                        max_players: data.max_players,
                        map: data.map,
                        port: data.port,
                        mods: data.mods,
                        upnp_enabled: true,
                        ..Default::default()
                    };
                    let rt = tokio::runtime::Runtime::new().unwrap();
                    rt.block_on(async move {
                        let server = kissmp_server::Server::from_config(config);
                        server.run(false, destroyer_rx, Some(setup_result_tx)).await;
                    });
                });
                // FIXME: Utilize setup response at some point. Like display dialog message on client with copy button instead of chat message
                loop {
                    let result = setup_result_rx.try_recv();
                    if result.is_ok() {
                        break;
                    }
                }
                let response = tiny_http::Response::from_string("ok");
                request.respond(response).unwrap();
                continue;
            }
            match reqwest::get(&url).await {
                Ok(response) => match response.text().await {
                    Ok(text) => {
                        let response = tiny_http::Response::from_string(text);
                        request.respond(response).unwrap();
                    }
                    Err(err) => {
                        let response = tiny_http::Response::from_string(format!(
                            "proxy_error: failed to read master response ({})",
                            err
                        ));
                        request.respond(response).unwrap();
                    }
                },
                Err(err) => {
                    let response = tiny_http::Response::from_string(format!(
                        "proxy_error: master unreachable ({})",
                        err
                    ));
                    request.respond(response).unwrap();
                }
            }
        }
    }
}
