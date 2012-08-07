
-module(ejabberd_auth_json).
-author('samuel.wejeus@opera.com').

-include("ejabberd.hrl").

%% External exports
-export([start/1,
	 stop/1,
	 set_password/3,
	 check_password/3,
	 check_password/4,
	 check_password/5,
	 try_register/3,
	 dirty_get_registered_users/0,
	 get_vh_registered_users/1,
	 get_vh_registered_users_number/1,
	 get_password/2,
	 get_password_s/2,
	 is_user_exists/2,
	 store_type/0,
	 remove_user/2,
	 remove_user/3,
	 plain_password_required/0
	]).


-record(state, {socket,
		sockmod,
		socket_monitor,
		xml_socket,
		streamid,
		sasl_state,
		access,
		shaper,
		zlib = false,
		tls = false,
		tls_required = false,
		tls_enabled = false,
		tls_options = [],
		authenticated = false,
		jid,
		user = undefined, server = list_to_binary(?MYNAME), resource = undefined,
		sid,
		pres_t,
		pres_f,
		pres_a,
		pres_i,
		pres_last, pres_pri,
		pres_timestamp,
		privacy_list,
		conn = unknown,
		auth_module = unknown,
		ip,
		aux_fields = [],
		fsm_limit_opts,
		lang,
        flash_connection = false}).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%% @spec (Host) -> ok
%%     Host = string()
start(Host) ->
	?DEBUG("Starting JSON authentication service on host: \"~s\"",[Host]),
	ok.

stop(Host) ->
	?DEBUG("Shutting down JSON authentication service on host: \"~s\"",[Host]),
    ok.

%% @spec () -> bool()
plain_password_required() ->
    true.

store_type() ->
    external.

%% @spec (User, Server, Password) -> bool()
%%     User = string() = JID Node
%%     Server = string() = JID Domain
%%     Password = string()
check_password(User, Server, Password) ->
	Jid = exmpp_jid:make(User, Server),
	opera_api:authenticate_user(Jid, Password).


check_password(User, Server, Password, SocketState) ->
	%?INFO_MSG("STATE: ~p~n", [SocketState]),
	{{Octet1,Octet2,Octet3,Octet4}, Port} = SocketState#state.ip,
	IP = lists:flatten(io_lib:format("~b.~b.~b.~b:~b)", [Octet1, Octet2, Octet3, Octet4, Port])),
	{_, Security, _, _} = SocketState#state.socket,
	Jid = exmpp_jid:make(User, Server),
	opera_api:authenticate_user(Jid, Password, IP, Security).

%% @spec (User, Server, Password, Digest, DigestGen) -> bool()
%%     User = string()
%%     Server = string()
%%     Password = string()
%%     Digest = string()
%%     DigestGen = function()
check_password(User, Server, Password, _Digest, _DigestGen) ->
	check_password(User, Server, Password).
	
	
	
	

%%%----------------------------------------------------------------------
%%% Forbidden or unused API calls.
%%%----------------------------------------------------------------------

%% @spec () -> [{LUser, LServer}]
%%     LUser = string()
%%     LServer = string()
%% @doc Get all registered users in Mnesia.
dirty_get_registered_users() ->
    [{"dummy_user", "dev.null"}].

%% @spec (Server) -> [{LUser, LServer}]
%%     Server = string()
%%     LUser = string()
%%     LServer = string()
get_vh_registered_users(_Server) ->
	[{"dummy_user", "dev.null"}].

%% @spec (Server) -> Users_Number
%%     Server = string()
%%     Users_Number = integer()
get_vh_registered_users_number(_Server) ->
	0.
	
%% @spec (User, Server) -> Password | false
%%     User = string()
%%     Server = string()
%%     Password = string()
get_password(_User, _Server) ->
	("no_password").

%% @spec (User, Server) -> Password | nil()
%%     User = string()
%%     Server = string()
%%     Password = string()
get_password_s(_User, _Server) ->
	("no_password").

%% @spec (User, Server) -> true | false | {error, Error}
%%     User = string()
%%     Server = string()
is_user_exists(_User, _Server) ->
	true.

%% @spec (User, Server, Password) -> ok | {error, invalid_jid}
%%     User = string()
%%     Server = string()
%%     Password = string()
%%	   Change of password thru XMPP client is not allowed. Just returns ok on whatever.
set_password(_User, _Server, _Password) ->
	ok.
	
%% @spec (User, Server) -> ok
%%     User = string()
%%     Server = string()
%% @doc Remove user.
%% Note: it returns ok even if there was some problem removing the user.
remove_user(_User, _Server) ->
	ok.
	
%% @spec (User, Server, Password) -> {atomic, ok} | {atomic, exists} | {error, invalid_jid} | {aborted, Reason}
%%     User = string()
%%     Server = string()
%%     Password = string()
try_register(_User, _Server, _Password) ->
	{aborted, "json auth does not allow inband registration."}.
	
%% @spec (User, Server, Password) -> ok | not_exists | not_allowed | bad_request
%%     User = string()
%%     Server = string()
%%     Password = string()
%% @doc Remove user if the provided password is correct.
remove_user(_User, _Server, _Password) ->
	not_allowed.



