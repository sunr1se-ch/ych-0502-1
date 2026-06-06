use axum::{
    extract::DefaultBodyLimit,
    routing::{get, patch, post},
    Router,
};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::net::SocketAddr;
use tower_http::cors::{Any, CorsLayer};
use tower_http::services::ServeDir;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

mod analysis;
mod models;
mod routes;

#[derive(Clone)]
pub struct AppState {
    db: PgPool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "reeling_factory_backend=debug,tower_http=debug".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let database_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://reeling:reeling123@localhost:5432/reeling_db".into());

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(&database_url)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;

    let app_state = AppState { db: pool };

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let api_routes = Router::new()
        .route(
            "/batches",
            get(routes::list_batches).post(routes::create_batch),
        )
        .route("/batches/:id", get(routes::get_batch))
        .route("/batches/:id/report", get(routes::export_report))
        .route("/batches/:id/outbound", patch(routes::mark_outbound))
        .route("/batches/:id/boil", post(routes::record_boil))
        .route("/batches/:id/float", post(routes::record_float));

    let app = Router::new()
        .nest("/api", api_routes)
        .nest_service("/", ServeDir::new("../frontend/dist"))
        .layer(cors)
        .layer(DefaultBodyLimit::max(10 * 1024 * 1024))
        .with_state(app_state);

    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    tracing::info!("listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}
