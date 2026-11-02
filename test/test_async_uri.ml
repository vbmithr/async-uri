(* A TLS connection is accepted only from a server whose certificate names the
   host connected to. The certificates are signed by a test CA of their
   own, valid until 2126: [localhost.pem] for localhost, [wrong.pem] for
   wrong.example. *)

open Core
open Async

let with_server ~cert f =
  Async_uri.listen_ssl ~crt_file:(cert ^ ".pem") ~key_file:(cert ^ ".key")
    ~on_handler_error:`Ignore Tcp.Where_to_listen.of_port_chosen_by_os
    (fun _addr _conn _r _w -> Deferred.unit)
  >>= fun server ->
  let port = Tcp.Server.listening_on server in
  Monitor.protect
    (fun () -> f (Uri.make ~scheme:"https" ~host:"localhost" ~port ()))
    ~finally:(fun () -> Tcp.Server.close server)

let connect ?ca_file url =
  Monitor.try_with ~extract_exn:true (fun () -> Async_uri.connect ?ca_file url)
  >>= function
  | Ok (conn : Async_uri.t) ->
      Writer.close conn.w >>= fun () ->
      Reader.close conn.r >>| fun () -> Ok ()
  | Error exn -> return (Error (Exn.to_string exn))

let check_refused name ~mentioning = function
  | Ok () -> Alcotest.failf "%s: the connection was accepted" name
  | Error message ->
      if not (String.is_substring message ~substring:mentioning) then
        Alcotest.failf "%s: refused for another reason: %s" name message

let right_name () =
  with_server ~cert:"localhost" (fun url ->
      connect ~ca_file:"ca.pem" url >>| function
      | Ok () -> ()
      | Error message -> Alcotest.failf "refused: %s" message)

(* The case that matters: a certificate that chains to a trusted root, for
   another name. *)
let wrong_name () =
  with_server ~cert:"wrong" (fun url ->
      connect ~ca_file:"ca.pem" url
      >>| check_refused "wrong.example for localhost"
            ~mentioning:"not valid for localhost")

let untrusted_root () =
  with_server ~cert:"localhost" (fun url ->
      connect url
      >>| check_refused "no test CA" ~mentioning:"certificate verify failed")

let no_host () =
  connect (Uri.of_string "https:///path") >>| function
  | Ok () -> Alcotest.fail "a TLS URL with no host was accepted"
  | Error _ -> ()

let () =
  don't_wait_for
    (Alcotest_async.run "async-uri"
       [
         ( "tls host",
           [
             Alcotest_async.test_case "right name" `Quick right_name;
             Alcotest_async.test_case "wrong name" `Quick wrong_name;
             Alcotest_async.test_case "untrusted root" `Quick untrusted_root;
             Alcotest_async.test_case "no host" `Quick no_host;
           ] );
       ]);
  never_returns (Scheduler.go ())
