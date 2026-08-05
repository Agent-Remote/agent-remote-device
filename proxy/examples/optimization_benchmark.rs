use std::{fs, path::PathBuf, process::ExitCode};

use agent_remote_device_proxy::telemetry::{OptimizationEvent, OptimizationSummary};
use clap::Parser;
#[cfg(test)]
use serde::Deserialize;
use serde::Serialize;

#[derive(Debug, Parser)]
#[command(name = "optimization_benchmark")]
struct Args {
    /// One or more v1 or legacy-helper zero-content traces.
    #[arg(long, required = true)]
    baseline: Vec<PathBuf>,
    /// One or more v2 AX-first zero-content traces.
    #[arg(long, required = true)]
    candidate: Vec<PathBuf>,
}

#[derive(Debug, Serialize)]
struct BenchmarkComparison {
    baseline: OptimizationSummary,
    candidate: OptimizationSummary,
    model_visible_image_reduction: f64,
    bridge_byte_reduction: f64,
    action_latency_p95_reduction: f64,
    call_success_rate_delta: f64,
    passes_recommended_targets: bool,
}

fn main() -> ExitCode {
    let args = Args::parse();
    let baseline = match load_summary(&args.baseline) {
        Ok(summary) => summary,
        Err(error) => {
            eprintln!("invalid baseline: {error}");
            return ExitCode::FAILURE;
        }
    };
    let candidate = match load_summary(&args.candidate) {
        Ok(summary) => summary,
        Err(error) => {
            eprintln!("invalid candidate: {error}");
            return ExitCode::FAILURE;
        }
    };
    if baseline.tool_calls == 0 || candidate.tool_calls == 0 {
        eprintln!("baseline and candidate must each contain at least one event");
        return ExitCode::FAILURE;
    }

    let comparison = compare(baseline, candidate);
    match serde_json::to_string_pretty(&comparison) {
        Ok(value) => {
            println!("{value}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("failed to encode comparison: {error}");
            ExitCode::FAILURE
        }
    }
}

fn compare(baseline: OptimizationSummary, candidate: OptimizationSummary) -> BenchmarkComparison {
    let image_reduction = reduction(
        baseline.model_visible_images,
        candidate.model_visible_images,
    );
    let bridge_reduction = reduction(baseline.bridge_bytes, candidate.bridge_bytes);
    let latency_reduction = reduction(
        u64::from(baseline.action_latency_p95_ms),
        u64::from(candidate.action_latency_p95_ms),
    );
    let passes_recommended_targets = image_reduction >= 0.70
        && candidate.action_latency_p95_ms <= 1_000
        && candidate.settle_latency_p95_ms <= 5_000
        && candidate.coordinate_fallback_rate < 0.20
        && candidate.call_success_rate >= baseline.call_success_rate;
    BenchmarkComparison {
        call_success_rate_delta: candidate.call_success_rate - baseline.call_success_rate,
        baseline,
        candidate,
        model_visible_image_reduction: image_reduction,
        bridge_byte_reduction: bridge_reduction,
        action_latency_p95_reduction: latency_reduction,
        passes_recommended_targets,
    }
}

fn load_summary(paths: &[PathBuf]) -> Result<OptimizationSummary, String> {
    let mut events = Vec::new();
    for path in paths {
        let bytes = fs::read(path).map_err(|error| format!("{}: {error}", path.display()))?;
        let mut trace: Vec<OptimizationEvent> = match serde_json::from_slice(&bytes) {
            Ok(trace) => trace,
            Err(_) => bytes
                .split(|value| *value == b'\n')
                .filter(|line| !line.is_empty())
                .map(serde_json::from_slice)
                .collect::<Result<Vec<_>, _>>()
                .map_err(|error| format!("{}: {error}", path.display()))?,
        };
        events.append(&mut trace);
    }
    Ok(OptimizationSummary::from_events(&events))
}

fn reduction(baseline: u64, candidate: u64) -> f64 {
    if baseline == 0 {
        if candidate == 0 {
            0.0
        } else {
            -1.0
        }
    } else {
        (baseline as f64 - candidate as f64) / baseline as f64
    }
}

#[cfg(test)]
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GoldenPromptSet {
    schema_version: u8,
    cases: Vec<GoldenPromptCase>,
}

#[cfg(test)]
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GoldenPromptCase {
    id: String,
    category: String,
    prompt: String,
    expected_skill_activation: bool,
    preferred_surface: String,
    first_observation_mode: Option<String>,
    expects_image: bool,
    confirmation_checkpoint: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn comparison_enforces_every_recommended_target() {
        let baseline = summary(100, 10_000, 1_400, 0.0, 0.95);
        let candidate = summary(20, 2_000, 800, 0.10, 0.96);
        assert!(compare(baseline.clone(), candidate.clone()).passes_recommended_targets);

        let mut regressed = candidate;
        regressed.call_success_rate = 0.94;
        assert!(!compare(baseline, regressed).passes_recommended_targets);
    }

    #[test]
    fn reductions_handle_zero_baselines_without_dividing_by_zero() {
        assert_eq!(reduction(0, 0), 0.0);
        assert_eq!(reduction(0, 1), -1.0);
        assert_eq!(reduction(10, 3), 0.7);
    }

    #[test]
    fn golden_prompt_corpus_is_strict_complete_and_unique() {
        let corpus: GoldenPromptSet = serde_json::from_str(include_str!(
            "../../benchmark/computer-use-golden-prompts.json"
        ))
        .expect("golden prompt corpus");
        assert_eq!(corpus.schema_version, 1);
        assert!(corpus.cases.len() >= 10);
        let mut ids = BTreeSet::new();
        let mut categories = BTreeSet::new();
        let mut surfaces = BTreeSet::new();
        for case in corpus.cases {
            assert!(!case.id.is_empty() && ids.insert(case.id));
            assert!(!case.prompt.trim().is_empty());
            assert!(["direct", "indirect", "browser", "alternative", "negative"]
                .contains(&case.category.as_str()));
            assert!(["device_v2", "connector", "cli", "none"]
                .contains(&case.preferred_surface.as_str()));
            if case.expected_skill_activation {
                assert_eq!(case.preferred_surface, "device_v2");
                assert!(case.first_observation_mode.is_some());
            } else {
                assert!(case.first_observation_mode.is_none());
                assert!(!case.expects_image);
            }
            assert!([
                "none",
                "before_submit",
                "before_purchase",
                "before_delete",
                "user_handoff"
            ]
            .contains(&case.confirmation_checkpoint.as_str()));
            categories.insert(case.category);
            surfaces.insert(case.preferred_surface);
        }
        assert_eq!(categories.len(), 5);
        assert_eq!(
            surfaces,
            BTreeSet::from([
                "cli".to_owned(),
                "connector".to_owned(),
                "device_v2".to_owned(),
                "none".to_owned(),
            ])
        );
    }

    fn summary(
        images: u64,
        bridge_bytes: u64,
        action_p95: u32,
        coordinate_rate: f64,
        success_rate: f64,
    ) -> OptimizationSummary {
        OptimizationSummary {
            schema_version: 1,
            tool_calls: 100,
            v1_calls: 0,
            v2_calls: 100,
            successful_calls: (success_rate * 100.0) as u64,
            model_visible_images: images,
            ax_bytes: 0,
            image_bytes: 0,
            bridge_bytes,
            action_latency_p50_ms: action_p95 / 2,
            action_latency_p95_ms: action_p95,
            settle_latency_p95_ms: 4_000,
            stale_target_rate: 0.0,
            coordinate_fallback_rate: coordinate_rate,
            call_success_rate: success_rate,
            manual_recovery_rate: 0.0,
        }
    }
}
