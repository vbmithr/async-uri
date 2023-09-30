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
   uri-sexp
  (core (>= v0.16))
  (async (>= v0.16))
  (async_ssl (>= v0.16)))
 (tags
  (async uri tls ssl)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/dune-files.html#dune-project
