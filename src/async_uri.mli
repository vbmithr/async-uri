open Async

val is_tls_url : Uri.t -> bool

val with_connection_uri :
  (Uri.t ->
   ((Uri.t -> ([ `Active ], Socket.Address.Inet.t) Socket.t ->
     Reader.t -> Writer.t -> 'a Deferred.t) ->
    'a Deferred.t)) Tcp.with_connect_options
