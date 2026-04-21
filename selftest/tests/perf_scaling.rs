//! Fixture perf-scaling test exercised by `perf-smoke.yml` and `nightly-perf.yml`.

#[test]
fn scaling_fixture_passes() {
    assert_eq!(greentic_reusable_selftest::greet().len(), 15);
}
