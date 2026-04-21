//! Trivial fixture library exercised by greenticai/.github's reusable-workflow self-test.
//! See `.github/workflows/self-test.yml`.

pub fn greet() -> &'static str {
    "hello, greentic"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greet_returns_expected_message() {
        assert_eq!(greet(), "hello, greentic");
    }
}
