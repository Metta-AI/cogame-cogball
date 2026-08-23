## Tests run from the repo ROOT (`nim r --path:src tests/<file>.nim`), so the
## assets they load resolve via `data/`. `tests/lib/` holds the shared harness:
## keeping it out of `tests/*.nim` means CI's default glob runs exactly the
## suites and nothing else.
switch("path", "../src")
switch("threads", "on")
