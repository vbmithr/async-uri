# async-uri

Open [Async](https://github.com/janestreet/async) TCP connections from a
`Uri.t`, with TLS when the URL's scheme calls for it.

`https` and `wss` URLs get TLS, with the server's certificate and hostname
verified. Every other scheme gets plain TCP. Either way you get back the same
`Reader.t` and `Writer.t`, so the code using the connection does not change.

## Installation

```sh
opam pin add async-uri git+https://github.com/vbmithr/async-uri
```

It requires OCaml with Async v0.17 or later. The library is `async-uri` in a
`dune` file, and its module is `Async_uri`.

## Usage

`with_connection` closes the connection when your function's result is
determined, or if it raises:

```ocaml
open Core
open Async

let get url =
  Async_uri.with_connection url (fun { r; w; _ } ->
    Writer.writef
      w
      "GET %s HTTP/1.0\r\nHost: %s\r\n\r\n"
      (Uri.path_and_query url)
      (Option.value_exn (Uri.host url));
    Reader.contents r)
;;

let main () = get (Uri.of_string "https://example.com/") >>| print_string
```

`connect` is the same, except that closing the connection is up to you.

The port comes from the URL if it names one, and otherwise from the scheme.
A URL with neither raises `Invalid_argument`.

### Verifying the server

A TLS connection is only handed back once the server's certificate has been
checked:

- It must chain to a trusted root: the system's store, or `?ca_file` if you
  give one.
- It must be valid for the URL's host. A URL with no host is refused.

Certificate IP addresses are not matched, so a TLS URL whose host is an IP
address always fails.

### Timeouts and interruption

- `?timeout` limits the TCP connect and the TLS handshake separately, so a TLS
  connection can take up to twice as long. Without it, the connect is limited
  to 10 seconds and the handshake to 5.
- `?interrupt` stops the TCP connect only. It does not affect the TLS handshake
  or a connection that is already established.

It is safe to share one long-lived `?interrupt`, such as a shutdown signal,
between any number of connections: nothing stays attached to it after a
connection is made.

### Reconnecting

`Async_uri.Persistent` is
[`Persistent_connection_kernel`](https://github.com/janestreet/async_kernel)
over this connection type. It reconnects whenever the connection is lost:

```ocaml
let persistent url =
  Async_uri.Persistent.create
    ~server_name:(Uri.to_string url)
    ~connect:(fun url ->
      Monitor.try_with_or_error (fun () -> Async_uri.connect url))
    (fun () -> Deferred.Or_error.return url)
;;
```

### Serving TLS

`listen_ssl` starts a `Tcp.Server` whose handler receives the established TLS
connection:

```ocaml
let serve () =
  Async_uri.listen_ssl
    ~crt_file:"server.pem"
    ~key_file:"server.key"
    ~on_handler_error:`Raise
    Tcp.Where_to_listen.of_port_chosen_by_os
    (fun _addr _conn r w ->
       Reader.lines r |> Pipe.iter_without_pushback ~f:(Writer.write_line w))
;;
```

### Async RPC

`connect_rpc` opens an Async RPC connection from a `tcp://host:port` or
`unix:///path/to/socket` URL. It raises on any other scheme, and on a `tcp` URL
without both a host and a port. It does not use TLS.

```ocaml
let rpc () = Async_uri.connect_rpc (Uri.of_string "tcp://localhost:8080")
```

## License

[ISC](LICENSE.md)
