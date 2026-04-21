//! Fixture criterion bench exercised by `nightly-perf.yml`.

use criterion::{Criterion, criterion_group, criterion_main};

fn fixture_bench(c: &mut Criterion) {
    c.bench_function("greet", |b| {
        b.iter(greentic_reusable_selftest::greet);
    });
}

criterion_group!(benches, fixture_bench);
criterion_main!(benches);
