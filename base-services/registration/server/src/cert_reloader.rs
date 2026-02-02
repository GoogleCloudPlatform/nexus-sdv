use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use rustls::server::WebPkiClientVerifier;
use rustls::ServerConfig;
use tokio::sync::mpsc;
use tracing::{error, info, warn};

use crate::certificates;

/// Holds the current TLS configuration that can be atomically swapped
/// when certificates are reloaded.
pub struct ReloadableServerConfig {
    config: Arc<ArcSwap<ServerConfig>>,
}

impl ReloadableServerConfig {
    /// Creates a new reloadable server config with the initial configuration
    pub fn new(initial_config: ServerConfig) -> Self {
        Self {
            config: Arc::new(ArcSwap::from_pointee(initial_config)),
        }
    }

    /// Gets the current server configuration
    pub fn get(&self) -> arc_swap::Guard<Arc<ServerConfig>> {
        self.config.load()
    }

    /// Updates the server configuration atomically
    pub fn update(&self, new_config: ServerConfig) {
        self.config.store(Arc::new(new_config));
    }

    /// Returns a clone of the inner Arc for sharing across tasks
    pub fn shared(&self) -> Arc<ArcSwap<ServerConfig>> {
        self.config.clone()
    }
}

impl Clone for ReloadableServerConfig {
    fn clone(&self) -> Self {
        Self {
            config: self.config.clone(),
        }
    }
}

/// Builds a new ServerConfig from the certificate files
pub fn build_server_config() -> anyhow::Result<ServerConfig> {
    let (server_certs, server_key) = certificates::read_server_certificate()?;
    let trusted_client_store = certificates::read_trusted_client_certificates_ca()?;

    let client_verifier = WebPkiClientVerifier::builder(trusted_client_store)
        .allow_unauthenticated()
        .build()
        .map_err(|e| anyhow::anyhow!("Failed to build client verifier: {}", e))?;

    let config = ServerConfig::builder()
        .with_client_cert_verifier(client_verifier)
        .with_single_cert(server_certs, server_key)
        .map_err(|e| anyhow::anyhow!("Failed to build server config: {}", e))?;

    Ok(config)
}

/// Starts watching the certificates directory for changes and reloads
/// the server configuration when changes are detected.
///
/// Returns a handle that keeps the watcher alive. Drop it to stop watching.
pub async fn start_certificate_watcher(
    reloadable_config: ReloadableServerConfig,
    watch_path: &Path,
) -> anyhow::Result<RecommendedWatcher> {
    let (tx, mut rx) = mpsc::channel::<Result<Event, notify::Error>>(100);

    // Create the watcher
    let mut watcher = notify::recommended_watcher(move |res| {
        // Send events through the channel (ignore send errors if receiver is dropped)
        let _ = tx.blocking_send(res);
    })?;

    // Watch the certificates directory
    watcher.watch(watch_path, RecursiveMode::Recursive)?;

    info!("Started watching {} for certificate changes", watch_path.display());

    // Spawn a task to handle file change events
    let config_clone = reloadable_config.clone();
    tokio::spawn(async move {
        // Debounce: wait for events to settle before reloading
        let debounce_duration = Duration::from_secs(2);
        let mut last_reload = std::time::Instant::now();
        let mut pending_reload = false;

        loop {
            tokio::select! {
                Some(event_result) = rx.recv() => {
                    match event_result {
                        Ok(event) => {
                            // Only reload on modify or create events for .pem files
                            let dominated_event = matches!(
                                event.kind,
                                EventKind::Modify(_) | EventKind::Create(_)
                            );

                            let is_pem_file = event.paths.iter().any(|p| {
                                p.extension().map_or(false, |ext| ext == "pem")
                            });

                            if dominated_event && is_pem_file {
                                info!("Certificate file change detected: {:?}", event.paths);
                                pending_reload = true;
                            }
                        }
                        Err(e) => {
                            warn!("File watcher error: {}", e);
                        }
                    }
                }
                _ = tokio::time::sleep(Duration::from_millis(500)) => {
                    // Check if we should reload (debounce)
                    if pending_reload && last_reload.elapsed() >= debounce_duration {
                        pending_reload = false;
                        last_reload = std::time::Instant::now();

                        info!("Reloading certificates...");
                        match build_server_config() {
                            Ok(new_config) => {
                                config_clone.update(new_config);
                                info!("Certificates reloaded successfully");
                            }
                            Err(e) => {
                                error!("Failed to reload certificates: {}. Keeping existing configuration.", e);
                            }
                        }
                    }
                }
            }
        }
    });

    Ok(watcher)
}