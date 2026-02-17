# Updating this book

This book is built using [mdBook](https://rust-lang.github.io/mdBook/), which in
turn requires a recent version of `rust` and `cargo` installed.

```sh
# Install correct versions of tooling
nimble mdbook

# Run a local mdbook server
mdbook serve docs
```

A [CI job](../../.github/workflows/docs.yml) automatically published the book
to [GitHub Pages](https://pages.github.com/).
