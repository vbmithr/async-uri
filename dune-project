(lang dune 3.10)

(name async-uri)

(generate_opam_files true)

(source
 (github vbmithr/async-uri))

(authors "Vincent Bernardoff <vb@luminar.eu.org>")

(maintainers "Vincent Bernardoff <vb@luminar.eu.org>")

(license ISC)

(documentation https://vbmithr.github.io/async-uri)

(package
 (name async-uri)
 (synopsis "Open Async (TLS) TCP connections with Uri.t")
 (description "Simple wrapper to the Async's Tcp module to
open connections from URLs. If the URL scheme is detected to require
TLS, TLS will be used.")
 (depends
  ocaml
  dune
  logs
  ppx_jane
  uri
  uri-sexp
  (core (>= v0.17))
  (async (>= v0.17))
  (async_ssl (>= v0.17))
  (alcotest :with-test)
  (alcotest-async :with-test))
 (tags
  (async uri tls ssl)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/dune-files.html#dune-project
