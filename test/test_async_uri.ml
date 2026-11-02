(* A TLS connection is accepted only from a server whose certificate names the
   host connected to. The certificates are signed by a test CA of their
   own, valid until 2126: [localhost.pem] for localhost, [wrong.pem] for
   wrong.example. *)

open Core
open Async

let with_server ~cert f =
  Async_uri.listen_ssl
    ~crt_file:(cert ^ ".pem")
    ~key_file:(cert ^ ".key")
    ~on_handler_error:`Ignore
    Tcp.Where_to_listen.of_port_chosen_by_os
    (fun _addr _conn _r _w -> Deferred.unit)
  >>= fun server ->
  let port = Tcp.Server.listening_on server in
  Monitor.protect
    (fun () -> f (Uri.make ~scheme:"https" ~host:"localhost" ~port ()))
    ~finally:(fun () -> Tcp.Server.close server)
;;

let connect ?ca_file url =
  Monitor.try_with ~extract_exn:true (fun () -> Async_uri.connect ?ca_file url)
  >>= function
  | Ok (conn : Async_uri.t) ->
    Writer.close conn.w >>= fun () -> Reader.close conn.r >>| fun () -> Ok ()
  | Error exn -> return (Error (Exn.to_string exn))
;;

let check_refused name ~mentioning = function
  | Ok () -> Alcotest.failf "%s: the connection was accepted" name
  | Error message ->
    if not (String.is_substring message ~substring:mentioning)
    then Alcotest.failf "%s: refused for another reason: %s" name message
;;

let right_name () =
  with_server ~cert:"localhost" (fun url ->
    connect ~ca_file:"ca.pem" url
    >>| function
    | Ok () -> ()
    | Error message -> Alcotest.failf "refused: %s" message)
;;

(* The case that matters: a certificate that chains to a trusted root, for
   another name. *)
let wrong_name () =
  with_server ~cert:"wrong" (fun url ->
    connect ~ca_file:"ca.pem" url
    >>| check_refused "wrong.example for localhost" ~mentioning:"not valid for localhost")
;;

let untrusted_root () =
  with_server ~cert:"localhost" (fun url ->
    connect url >>| check_refused "no test CA" ~mentioning:"certificate verify failed")
;;

let no_host () =
  connect (Uri.of_string "https:///path")
  >>| function
  | Ok () -> Alcotest.fail "a TLS URL with no host was accepted"
  | Error _ -> ()
;;

(* A process-lifetime [interrupt] outlives every connection made with it, so a
   connection must leave nothing behind on it. *)
let live_words () =
  let collect () = Scheduler.yield () >>| fun () -> Gc.full_major () in
  collect () >>= collect >>| fun () -> (Gc.stat ()).live_words
;;

let words_per_connection f =
  let connections = 300 in
  let run n =
    Deferred.List.iter ~how:`Sequential (List.init n ~f:Fn.id) ~f:(fun _ -> f ())
  in
  run 100
  >>= fun () ->
  live_words ()
  >>= fun before ->
  run connections
  >>= fun () -> live_words () >>| fun after -> (after - before) / connections
;;

let with_plain_server f =
  Tcp.Server.create
    ~on_handler_error:`Ignore
    Tcp.Where_to_listen.of_port_chosen_by_os
    (fun _addr _r _w -> Deferred.unit)
  >>= fun server ->
  let port = Tcp.Server.listening_on server in
  Monitor.protect
    (fun () -> f (Uri.make ~scheme:"tcp" ~host:"127.0.0.1" ~port ()))
    ~finally:(fun () -> Tcp.Server.close server)
;;

let leaves_nothing_on_interrupt
      (make : ?interrupt:unit Deferred.t -> Uri.t -> unit Deferred.t)
      ()
  =
  with_plain_server (fun url ->
    let stop = Ivar.create () in
    (* Without an interrupt: only so that lazily built state, on both sides
         of the connection as they share this process, is not counted below. *)
    words_per_connection (fun () -> make url)
    >>= fun (_ : int) ->
    words_per_connection (fun () -> make ~interrupt:(Ivar.read stop) url)
    >>| fun words ->
    (* Also what keeps [stop] alive until here: collected along with
         whatever was left on it, it would hide exactly what is measured. *)
    assert (Ivar.is_empty stop);
    if words > 8 then Alcotest.failf "%d words per connection left on the interrupt" words)
;;

let with_connection ?interrupt url =
  Async_uri.with_connection ?interrupt url (fun _ -> Deferred.unit)
;;

let connect_and_close ?interrupt url =
  Async_uri.connect ?interrupt url
  >>= fun (conn : Async_uri.t) -> Writer.close conn.w >>= fun () -> Reader.close conn.r
;;

let raises what f =
  Monitor.try_with ~extract_exn:true f
  >>| function
  | Ok () -> Alcotest.failf "%s succeeded" what
  | Error _ -> ()
;;

(* Failing to connect has to end the scope too. *)
let refused () =
  with_plain_server return
  >>= fun url ->
  let stop = Ivar.create () in
  raises "connecting to a closed port" (fun () ->
    connect_and_close ~interrupt:(Ivar.read stop) url)
;;

let still_interrupts () =
  let unroutable = Uri.make ~scheme:"tcp" ~host:"10.255.255.1" ~port:9 () in
  let stop = Ivar.create () in
  let attempt =
    raises "an interrupted connect" (fun () ->
      connect_and_close ~interrupt:(Ivar.read stop) unroutable)
  in
  Ivar.fill_exn stop ();
  Clock_ns.with_timeout (Time_ns.Span.of_int_sec 2) attempt
  >>| function
  | `Result () -> ()
  | `Timeout -> Alcotest.fail "the interrupt did not stop the connect"
;;

let () =
  don't_wait_for
    (Alcotest_async.run
       "async-uri"
       [ ( "tls host"
         , [ Alcotest_async.test_case "right name" `Quick right_name
           ; Alcotest_async.test_case "wrong name" `Quick wrong_name
           ; Alcotest_async.test_case "untrusted root" `Quick untrusted_root
           ; Alcotest_async.test_case "no host" `Quick no_host
           ] )
       ; ( "interrupt"
         , [ Alcotest_async.test_case
               "connect leaves nothing"
               `Quick
               (leaves_nothing_on_interrupt connect_and_close)
           ; Alcotest_async.test_case
               "with_connection leaves nothing"
               `Quick
               (leaves_nothing_on_interrupt with_connection)
           ; Alcotest_async.test_case "refused" `Quick refused
           ; Alcotest_async.test_case "still interrupts" `Quick still_interrupts
           ] )
       ]);
  never_returns (Scheduler.go ())
;;
