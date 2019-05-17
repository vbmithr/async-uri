open Core
open Async
open Async_ssl.Std

let is_tls_url url = match Uri.scheme url with
  | Some "https"
  | Some "wss" -> true
  | _ -> false

let ssl_connect r w =
  let net_to_ssl, net_to_ssl_w = Pipe.create () in
  let ssl_to_net_r, ssl_to_net = Pipe.create () in
  don't_wait_for (Pipe.transfer_id (Reader.pipe r) net_to_ssl_w) ;
  don't_wait_for (Pipe.transfer_id ssl_to_net_r (Writer.pipe w)) ;
  let app_to_ssl, client_w = Pipe.create () in
  let client_r, ssl_to_app = Pipe.create () in
  Ssl.client ~app_to_ssl ~ssl_to_app ~net_to_ssl ~ssl_to_net () >>= function
  | Error e -> Error.raise e
  | Ok conn ->
    Reader.of_pipe (Info.createf "ssl_r") client_r >>= fun client_r ->
    Writer.of_pipe (Info.createf "ssl_w") client_w >>=
    fun (client_w, `Closed_and_flushed_downstream flushed) ->
    return (conn, flushed, client_r, client_w)

let ssl_cleanup conn _flushed =
  Ssl.Connection.close conn ;
  Ssl.Connection.closed conn >>= fun _ ->
  Deferred.unit

let with_connection_uri
    ?buffer_age_limit
    ?interrupt
    ?reader_buffer_size
    ?writer_buffer_size
    ?timeout url f =
  let host = match Uri.host url with
    | None -> invalid_arg "no host in URL"
    | Some host -> host in
  let port =
    match Uri.port url, Uri_services.tcp_port_of_uri url with
    | Some p, _ -> p
    | None, Some p -> p
    | _ -> invalid_arg "no port in URL" in
  Unix.Inet_addr.of_string_or_getbyname host >>= fun inet_addr ->
  Tcp.with_connection
    ?buffer_age_limit ?interrupt ?reader_buffer_size ?writer_buffer_size ?timeout
    (Tcp.Where_to_connect.of_inet_address (`Inet (inet_addr, port)))
    begin fun s r w ->
      match is_tls_url url with
      | false -> f url s r w
      | true ->
        ssl_connect r w >>= fun (conn, flushed, r, w) ->
        Monitor.protect
          (fun () -> f url s r w)
          ~finally:(fun () -> ssl_cleanup conn flushed)
    end
