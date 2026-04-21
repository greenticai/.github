//! Fixture perf-timeout test exercised by `perf-smoke.yml` and `nightly-perf.yml`.

#[test]
fn timeout_fixture_passes() {
    assert!(greentic_reusable_selftest::greet().starts_with("hello"));
}
