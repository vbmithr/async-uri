open Async
open Async_ssl.Std

val is_tls_url : Uri.t -> bool

val connect :
  ?version:Async_ssl.Version.t ->
  ?options:Async_ssl.Opt.t list ->
  ?socket:([ `Unconnected ], Socket.Address.Inet.t) Socket.t ->
  (Uri.t ->
   (([ `Active ], Socket.Address.Inet.t) Socket.t *
    Ssl.Connection.t option * Reader.t * Writer.t) Deferred.t)
    Tcp.with_connect_options

val with_connection :
  ?version:Async_ssl.Version.t ->
  ?options:Async_ssl.Opt.t list ->
  (Uri.t ->
   ((([ `Active ], Socket.Address.Inet.t) Socket.t ->
     Ssl.Connection.t option ->
     Reader.t -> Writer.t -> 'a Deferred.t) ->
    'a Deferred.t)) Tcp.with_connect_options
