pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

pub mod config;
pub mod db;
pub mod errors;
pub mod grpc;
pub mod log;
pub mod proto;
pub mod services;
pub mod state;
pub mod telemetry;
pub mod views;
