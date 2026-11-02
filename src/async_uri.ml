open Core
open Async
open Async_ssl.Std

let src = Logs.Src.create "async.uri"

module Lo = (val Logs.src_log src : Logs.LOG)

let is_tls_url url =
  match Uri.scheme url with
  | Some "https" | Some "wss" -> true
  | _ -> false
;;

(* async_ssl gives [hostname] to SNI only, and its default [Verify_peer]
   checks that the chain reaches a trusted root, not that the certificate
   names this host: any publicly trusted certificate, for any domain,
   would do. Checked before the connection is handed back, so nothing is sent
   on one that fails. A URL with no host has nothing to check against. *)
let verify_host conn = function
  | None -> Or_error.error_string "TLS URL has no host to verify the certificate against"
  | Some host ->
    Ssl.Connection.check_peer_certificate_host conn host
    |> Or_error.tag ~tag:(sprintf "TLS certificate is not valid for %s" host)
;;

let ssl_connect ?version ?options ?ca_file ?(timeout = Time_ns.Span.of_int_sec 5) url r w =
  let net_to_ssl = Reader.pipe r in
  let ssl_to_net = Pipe.create_writer (fun r -> Pipe.transfer_id r (Writer.pipe w)) in
  let app_to_ssl, client_w = Pipe.create () in
  let client_r, ssl_to_app = Pipe.create () in
  let hostname = Uri.host url in
  let close_transport () =
    Pipe.close_read app_to_ssl;
    Pipe.close ssl_to_app;
    Deferred.all_unit [ Reader.close r; Writer.close w ]
  in
  Clock_ns.with_timeout
    timeout
    (Ssl.client
       ?hostname
       ?version
       ?options
       ?ca_file
       ~app_to_ssl
       ~ssl_to_app
       ~net_to_ssl
       ~ssl_to_net
       ())
  >>= function
  | `Timeout -> close_transport () >>= fun () -> failwith "SSL handshake timeout"
  | `Result (Error e) -> close_transport () >>= fun () -> Error.raise e
  | `Result (Ok conn) ->
    (match verify_host conn hostname with
     | Error e ->
       (* Not waited for: the fd is closed at once, but after a completed
           handshake [Writer.close w] does not become determined, as the
           writer still waits on the pipe TLS had attached to it. *)
       Ssl.Connection.close conn;
       don't_wait_for (close_transport ());
       Error.raise e
     | Ok () ->
       Reader.of_pipe (Info.createf "ssl_r") client_r
       >>= fun client_r ->
       Writer.of_pipe (Info.createf "ssl_w") client_w
       >>= fun (client_w, `Closed_and_flushed_downstream flushed) ->
       Monitor.detach_and_iter_errors
         (Writer.monitor w)
         ~f:(Monitor.send_exn (Writer.monitor client_w));
       don't_wait_for (Reader.close_finished client_r >>= fun () -> Reader.close r);
       don't_wait_for (Writer.close_finished client_w >>= fun () -> Writer.close w);
       (Deferred.all_unit
          [ Reader.close_finished client_r; Writer.close_finished client_w ]
        >>> fun () ->
        Lo.debug (fun m -> m "Closing SSL connection");
        Ssl.Connection.close conn);
       return (conn, flushed, client_r, client_w))
;;

module T = struct
  module Address = Uri_sexp

  type t =
    { s : ([ `Active ], Socket.Address.Inet.t) Socket.t
    ; ssl : Ssl.Connection.t option
    ; r : Reader.t
    ; w : Writer.t
    }

  let create ?ssl s r w = { s; ssl; r; w }

  let close { ssl; r; w; _ } =
    Option.iter ~f:Ssl.Connection.close ssl;
    Writer.close w >>= fun () -> Reader.close r
  ;;

  let close_finished { r; _ } = Reader.close_finished r
  let is_closed { r; _ } = Reader.is_closed r
end

include T
module Persistent = Persistent_connection_kernel.Make (T)

let port_of_url url =
  match Uri.port url, Uri_services.tcp_port_of_uri url, Uri.scheme url with
  | Some p, _, _ -> p
  | None, Some p, _ -> p
  | None, None, Some "wss" -> 443
  | _ -> invalid_arg "no port in URL"
;;

(* [Tcp] races [interrupt] against its connect timeout. A successful connect
   aborts the timeout, which leaves that race pending for as long as [interrupt]
   is, with its handler still registered: nothing for a short-lived interrupt,
   one retained closure chain per connection for a process-lifetime one. Only
   connecting is interruptible, so [Tcp] gets a deferred that ends with it. *)
let scoped_interrupt = function
  | None -> None, Fn.id
  | Some interrupt ->
    let connected = Ivar.create () in
    ( Some (Deferred.any [ interrupt; Ivar.read connected ])
    , fun () -> Ivar.fill_if_empty connected () )
;;

let connect
      ?version
      ?options
      ?ca_file
      ?socket
      ?buffer_age_limit
      ?interrupt
      ?reader_buffer_size
      ?writer_buffer_size
      ?timeout
      ?time_source
      url
  =
  let host = Option.value_exn ~message:"no host in URL" (Uri.host url) in
  let port = port_of_url url in
  let timeout_float = Option.map timeout ~f:Time_ns.Span.to_span_float_round_nearest in
  Unix.Inet_addr.of_string_or_getbyname host
  >>= fun inet_addr ->
  let interrupt, release = scoped_interrupt interrupt in
  Monitor.protect
    (fun () ->
       Tcp.connect
         ?socket
         ?buffer_age_limit
         ?interrupt
         ?reader_buffer_size
         ?writer_buffer_size
         ?timeout:timeout_float
         ?time_source
         (Tcp.Where_to_connect.of_inet_address (`Inet (inet_addr, port))))
    ~finally:(fun () ->
      release ();
      Deferred.unit)
  >>= fun (s, r, w) ->
  match is_tls_url url with
  | false -> return (create s r w)
  | true ->
    ssl_connect ?version ?options ?ca_file ?timeout url r w
    >>= fun (ssl, _flushed, r, w) -> return (create ~ssl s r w)
;;

let with_connection
      ?version
      ?options
      ?ca_file
      ?buffer_age_limit
      ?interrupt
      ?reader_buffer_size
      ?writer_buffer_size
      ?timeout
      ?time_source
      url
      f
  =
  let host = Option.value_exn ~message:"no host in URL" (Uri.host url) in
  let port = port_of_url url in
  let timeout_float = Option.map timeout ~f:Time_ns.Span.to_span_float_round_nearest in
  let hp = Tcp.Where_to_connect.of_host_and_port (Host_and_port.create ~host ~port) in
  let interrupt, release = scoped_interrupt interrupt in
  Monitor.protect
    (fun () ->
       Tcp.with_connection
         ?buffer_age_limit
         ?interrupt
         ?reader_buffer_size
         ?writer_buffer_size
         ?timeout:timeout_float
         ?time_source
         hp
         (fun s r w ->
            release ();
            match is_tls_url url with
            | false -> f (create s r w)
            | true ->
              ssl_connect ?version ?options ?ca_file ?timeout url r w
              >>= fun (ssl, _flushed, r, w) ->
              Monitor.protect
                (fun () -> f (create ~ssl s r w))
                ~finally:(fun () ->
                  (* Do not wait for close to be finished, writer inner
                     monitor could be stuck etc. *)
                  don't_wait_for (Reader.close r);
                  don't_wait_for (Writer.close w);
                  Deferred.unit)))
    ~finally:(fun () ->
      release ();
      Deferred.unit)
;;

let listen_ssl
      ?version
      ?options
      ?name
      ?allowed_ciphers
      ?ca_file
      ?ca_path
      ?verify_modes
      ~crt_file
      ~key_file
      ?buffer_age_limit
      ?max_connections
      ?max_accepts_per_batch
      ?backlog
      ?socket
      ~on_handler_error
      listen_on
      f
  =
  Tcp.Server.create
    ?buffer_age_limit
    ?max_connections
    ?max_accepts_per_batch
    ?backlog
    ?socket
    ~on_handler_error
    listen_on
    (fun s r w ->
       let ssl_to_net = Writer.pipe w in
       let net_to_ssl = Reader.pipe r in
       let app_to_ssl, client_write = Pipe.create () in
       let client_read, ssl_to_app = Pipe.create () in
       Reader.of_pipe (Info.of_string "read_pipe") client_read
       >>= fun r ->
       Writer.of_pipe (Info.of_string "writer_pipe") client_write
       >>= fun (w, _) ->
       Monitor.protect
         (fun () ->
            Ssl.server
              ?version
              ?options
              ?name
              ?allowed_ciphers
              ?ca_file
              ?ca_path
              ~crt_file
              ~key_file
              ?verify_modes
              ~ssl_to_net
              ~net_to_ssl
              ~app_to_ssl
              ~ssl_to_app
              ()
            |> Deferred.Or_error.ok_exn
            >>= fun c -> f s c r w)
         ~finally:(fun () ->
           Pipe.close ssl_to_net;
           Pipe.close_read net_to_ssl;
           Pipe.close_read app_to_ssl;
           Pipe.close_read client_read;
           Reader.close r >>= fun () -> Writer.close w))
;;

let connect_rpc ?implementations ?heartbeat_config ?identification addr =
  match Uri.scheme addr with
  | Some "unix" ->
    let path = Uri.path addr in
    Async_rpc.Rpc.Connection.client
      ?implementations
      ?heartbeat_config
      ?identification
      (Tcp.Where_to_connect.of_file path)
    |> Deferred.Or_error.of_exn_result
  | Some "tcp" ->
    (match Uri.host addr, Uri.port addr with
     | Some host, Some port ->
       let hp = Host_and_port.create ~host ~port in
       Async_rpc.Rpc.Connection.client
         ?implementations
         ?heartbeat_config
         ?identification
         (Tcp.Where_to_connect.of_host_and_port hp)
       |> Deferred.Or_error.of_exn_result
     | _ -> raise_s [%message "tcp: missing host or port in URL"])
  | _ -> raise_s [%message "only tcp or unix schemes are supported"]
;;
