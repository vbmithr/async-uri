open Async
open Async_ssl.Std

val is_tls_url : Uri.t -> bool

val connect :
  ?socket:([ `Unconnected ], Socket.Address.Inet.t) Socket.t ->
  (Uri.t ->
   (([ `Active ], Socket.Address.Inet.t) Socket.t *
    Ssl.Connection.t option * Reader.t * Writer.t) Deferred.t)
    Tcp.with_connect_options

val with_connection :
  (Uri.t ->
   ((([ `Active ], Socket.Address.Inet.t) Socket.t ->
     Ssl.Connection.t option ->
     Reader.t -> Writer.t -> 'a Deferred.t) ->
    'a Deferred.t)) Tcp.with_connect_options
