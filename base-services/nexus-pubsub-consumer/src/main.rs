use nexus_pubsub_consumer::{app, config, transport};

#[tokio::main]
async fn main() -> std::process::ExitCode {
    tracing_subscriber::fmt().with_target(false).init();

    let path = std::env::var("CONFIG_PATH").unwrap_or_else(|_| "config.toml".into());
    let cfg = match config::Config::load(&path) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("{e}");
            return std::process::ExitCode::from(2);
        }
    };

    let detail = cfg.log_detail;
    if let Err(e) = transport::run(&cfg, move |m| app::log_message(m, detail)).await {
        tracing::error!("{e}");
        return std::process::ExitCode::FAILURE;
    }
    std::process::ExitCode::SUCCESS
}
