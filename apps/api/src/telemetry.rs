//! Optional, opt-in telemetry configuration for the IronBook API.
//!
//! Phase-1 slice of the telemetry plan in #27: this module only parses
//! configuration, decides sampling, and scrubs sensitive attributes. It does
//! not install an OTLP exporter or emit any telemetry on its own, so enabling
//! it changes no runtime behaviour until a later phase wires it into the
//! tracing subscriber.
//!
//! Configuration (all optional, read through the existing `config` helper so
//! `.env` handling matches the rest of the API):
//!
//! | Variable                  | Default          | Meaning                                    |
//! |---------------------------|------------------|--------------------------------------------|
//! | `TELEMETRY_ENABLED`       | `false`          | Opt-in switch. Anything other than the   |
//! |                           |                  | exact string `true` (case-insensitive)   |
//! |                           |                  | leaves telemetry disabled.               |
//! | `TELEMETRY_SERVICE_NAME`  | `ironbook-api`   | Service name reported to the backend.    |
//! | `TELEMETRY_OTLP_ENDPOINT` | unset            | OTLP endpoint, e.g. `http://localhost:4317`. |
//! | `TELEMETRY_SAMPLE_RATIO`  | `1.0`            | Fraction of traces to sample, `0.0`–`1.0`. |
//!
//! A malformed `TELEMETRY_SAMPLE_RATIO` (not a number, `NaN`, infinite, or
//! outside `0.0..=1.0`) is a hard error instead of silently falling back:
//! silently sampling everything — or nothing — would hide a misconfiguration
//! in exactly the pipeline meant to surface problems.

use crate::config;

/// Service name used when `TELEMETRY_SERVICE_NAME` is unset or blank.
pub const DEFAULT_SERVICE_NAME: &str = "ironbook-api";

/// Attribute keys that must never leave the process. Matching is
/// case-insensitive, so `Authorization`, `AUTHORIZATION`, and `authorization`
/// are all dropped.
const SENSITIVE_KEYS: [&str; 9] = [
    "authorization",
    "cookie",
    "set-cookie",
    "api-key",
    "apikey",
    "x-api-key",
    "token",
    "password",
    "secret",
];

/// Parsed, validated telemetry configuration.
#[derive(Debug, Clone, PartialEq)]
pub struct TelemetryConfig {
    /// Master opt-in switch. `false` means nothing is sampled or exported.
    pub enabled: bool,
    /// Service name reported to the telemetry backend.
    pub service_name: String,
    /// OTLP endpoint, if one is configured.
    pub otlp_endpoint: Option<String>,
    /// Fraction of traces to sample, always within `0.0..=1.0`.
    pub sample_ratio: f64,
}

impl TelemetryConfig {
    /// Read configuration from the environment (via `config::get`).
    pub fn from_env() -> Result<Self, String> {
        Self::from_values(
            config::get("TELEMETRY_ENABLED").ok(),
            config::get("TELEMETRY_SERVICE_NAME").ok(),
            config::get("TELEMETRY_OTLP_ENDPOINT").ok(),
            config::get("TELEMETRY_SAMPLE_RATIO").ok(),
        )
    }

    /// Parse already-read variable values. Kept separate from `from_env` so
    /// the parsing rules are unit-testable without touching process env.
    pub fn from_values(
        enabled: Option<String>,
        service_name: Option<String>,
        otlp_endpoint: Option<String>,
        sample_ratio: Option<String>,
    ) -> Result<Self, String> {
        let enabled = enabled
            .map(|v| v.trim().to_lowercase() == "true")
            .unwrap_or(false);
        let service_name = service_name
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| DEFAULT_SERVICE_NAME.to_string());
        let otlp_endpoint = otlp_endpoint
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty());
        let sample_ratio = match sample_ratio {
            None => 1.0,
            Some(raw) => {
                let parsed: f64 = raw.trim().parse().map_err(|_| {
                    format!("TELEMETRY_SAMPLE_RATIO must be a number between 0.0 and 1.0, got {raw:?}")
                })?;
                if !parsed.is_finite() || !(0.0..=1.0).contains(&parsed) {
                    return Err(format!(
                        "TELEMETRY_SAMPLE_RATIO must be a number between 0.0 and 1.0, got {raw:?}"
                    ));
                }
                parsed
            }
        };
        Ok(Self {
            enabled,
            service_name,
            otlp_endpoint,
            sample_ratio,
        })
    }

    /// Deterministic sampling decision for a trace id.
    ///
    /// The same trace id always yields the same decision, so a sampled trace
    /// stays sampled across services. Disabled config never samples, and a
    /// ratio of `1.0` samples every id (including `u64::MAX`, which would
    /// otherwise round up to the `2^64` threshold in `f64` and be missed).
    pub fn should_sample(&self, trace_id: u64) -> bool {
        if !self.enabled {
            return false;
        }
        if self.sample_ratio >= 1.0 {
            return true;
        }
        if self.sample_ratio <= 0.0 {
            return false;
        }
        (trace_id as f64) < self.sample_ratio * (u64::MAX as f64)
    }
}

/// Drop sensitive attributes (see [`SENSITIVE_KEYS`]) from a key/value list.
///
/// This is the PII-scrubbing hook required by #27: callers pass span or
/// metric attributes through here before exporting them.
pub fn scrub_attributes(attributes: &[(String, String)]) -> Vec<(String, String)> {
    attributes
        .iter()
        .filter(|(key, _)| !SENSITIVE_KEYS.contains(&key.to_lowercase().as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn enabled(ratio: &str) -> TelemetryConfig {
        TelemetryConfig::from_values(
            Some("true".to_string()),
            None,
            None,
            Some(ratio.to_string()),
        )
        .expect("valid test config")
    }

    #[test]
    fn defaults_are_disabled_with_full_sampling() {
        let config = TelemetryConfig::from_values(None, None, None, None).unwrap();
        assert!(!config.enabled);
        assert_eq!(config.service_name, DEFAULT_SERVICE_NAME);
        assert_eq!(config.otlp_endpoint, None);
        assert_eq!(config.sample_ratio, 1.0);
        assert!(!config.should_sample(0));
    }

    #[test]
    fn enabled_flag_only_accepts_true() {
        for raw in ["true", "TRUE", " True "] {
            let config = TelemetryConfig::from_values(
                Some(raw.to_string()),
                None,
                None,
                None,
            )
            .unwrap();
            assert!(config.enabled, "{raw:?} should enable telemetry");
        }
        for raw in ["1", "yes", "on", ""] {
            let config = TelemetryConfig::from_values(
                Some(raw.to_string()),
                None,
                None,
                None,
            )
            .unwrap();
            assert!(!config.enabled, "{raw:?} must not enable telemetry");
        }
    }

    #[test]
    fn sample_ratio_bounds_are_rejected() {
        for raw in ["-0.1", "1.1", "NaN", "inf", "-inf", "not-a-number"] {
            assert!(
                TelemetryConfig::from_values(None, None, None, Some(raw.to_string())).is_err(),
                "{raw:?} must be rejected"
            );
        }
        for raw in ["0", "0.0", "0.5", "1", "1.0"] {
            assert!(
                TelemetryConfig::from_values(None, None, None, Some(raw.to_string())).is_ok(),
                "{raw:?} must be accepted"
            );
        }
    }

    #[test]
    fn sampling_boundaries_hold() {
        assert!(!enabled("0.0").should_sample(0));
        assert!(!enabled("0.0").should_sample(u64::MAX));
        assert!(enabled("1.0").should_sample(0));
        assert!(enabled("1.0").should_sample(u64::MAX));
        // Half sampling keeps the bottom half of the id space.
        assert!(enabled("0.5").should_sample(0));
        assert!(!enabled("0.5").should_sample(u64::MAX));
    }

    #[test]
    fn scrubbing_drops_sensitive_keys_case_insensitively() {
        let attributes = vec![
            ("Authorization".to_string(), "Bearer x".to_string()),
            ("COOKIE".to_string(), "session=abc".to_string()),
            ("x-api-key".to_string(), "secret".to_string()),
            ("user.id".to_string(), "42".to_string()),
            ("http.route".to_string(), "/users".to_string()),
        ];
        let scrubbed = scrub_attributes(&attributes);
        assert_eq!(
            scrubbed,
            vec![
                ("user.id".to_string(), "42".to_string()),
                ("http.route".to_string(), "/users".to_string()),
            ]
        );
    }

    #[test]
    fn blank_service_name_and_endpoint_fall_back() {
        let config = TelemetryConfig::from_values(
            Some("true".to_string()),
            Some("   ".to_string()),
            Some("  ".to_string()),
            None,
        )
        .unwrap();
        assert_eq!(config.service_name, DEFAULT_SERVICE_NAME);
        assert_eq!(config.otlp_endpoint, None);
    }
}
